;;;
;;; Copyright (c) 2009, Lorenz Moesenlechner <moesenle@cs.tum.edu>
;;; All rights reserved.
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions are met:
;;;
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;;     * Redistributions in binary form must reproduce the above copyright
;;;       notice, this list of conditions and the following disclaimer in the
;;;       documentation and/or other materials provided with the distribution.
;;;     * Neither the name of Willow Garage, Inc. nor the names of its
;;;       contributors may be used to endorse or promote products derived from
;;;       this software without specific prior written permission.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
;;; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
;;; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
;;; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
;;; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
;;; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
;;; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;;; POSSIBILITY OF SUCH DAMAGE.
;;;

(in-package :cpl-impl)

(define-task-variable *break-on-plan-failures* nil
  "Like *BREAK-ON-SIGNALS*, but for plan failures."
  :type (or symbol list))

(define-task-variable *debug-on-lisp-errors* t
  "Indicates if the debugger should be entered at the location where a
  common lisp error is raised.")

(defvar *retry-path* nil "Path variable used by the with-failure-handling and with-transformative-failure-handling macros. It denotes the path of the macros' BODY inside the task tree.")

(define-condition plan-failure (serious-condition) 
  ((code-path :initarg :code-path
              :reader plan-failure/get-code-path
              :initform nil))
  (:documentation
   "Condition which denotes a plan failure."))

(define-condition simple-plan-failure (simple-condition plan-failure) ())

(define-condition composite-failure (plan-failure)
  ((failures :initform nil :initarg :failures :reader composite-failures)))

(define-condition common-lisp-error-envelope (plan-failure)
  ((error :initarg :error :reader envelop-error)))

(defun coerce-to-condition (datum arguments default-type)
  (etypecase datum
    (condition (prog1 datum (assert (null arguments))))
    (symbol    (apply #'make-condition datum arguments))
    (string    (make-condition default-type
                               :format-control datum
                               :format-arguments arguments))))

(define-hook cram-language::on-fail (datum)
  (:documentation "Hook that is executed whenever a condition is
  signaled using FAIL."))

(defun %fail (datum args)
  (let ((current-task *current-task*)
        (condition (coerce-to-condition datum args 'simple-plan-failure)))
    (log-event
      (:context "FAIL")
      (:display "~S: ~_\"~A\"" condition condition)
      (:tags :fail))
    (cram-language::on-fail datum)
    (cond
      ;; The main thread will perform JOIN-TASK on the TOPLEVEL-TASK,
      ;; signal the condition for that case.
      ((not current-task)
       (error condition))
      ;; The condition does not designate a plan failure so just
      ;; signal it, entering the debugger if it remains unhandled.
      ((not (typep condition 'plan-failure))
       (error condition))
      ;; Does the user want us to enter the debugger on the plan
      ;; failure?
      ((and (typep condition *break-on-plan-failures*)
            (restart-case
                (with-condition-restarts condition
                    (list (find-restart 'propagate))
                  (without-scheduling
                    (invoke-debugger condition)))
              (continue ()
                :report "Continue failure signalling."
                nil))))                 ; fall through COND clause
      ;; An actual plan failure. Use SIGNAL here, too, so
      ;; WITH-FAILURE-HANDLING can be implemented on top of the normal
      ;; CL condition system.
      ;;
      ;; At the moment, ASSERT-NO-RETURNING, but in case inter-task
      ;; restarts are implemented, this has to change.
      (t
       (assert-no-returning
         (signal condition))))))

(defun fail (&rest args)
  "Function to generate a fail condition which includes the current code path among 
its member data if (car args) is of typep symbol."
  (if (null args)
      (%fail 'plan-failure (list :code-path *current-path*))
      (if (typep (car args) 'condition)
          (%fail (car args) (cdr args))
          (%fail (car args) (append (cdr args) `(:code-path ,*current-path*))))))

(cut:define-hook cram-language::on-with-failure-handling-begin (clauses))
(cut:define-hook cram-language::on-with-failure-handling-end (id))
(cut:define-hook cram-language::on-with-failure-handling-handled (id))
(cut:define-hook cram-language::on-with-failure-handling-rethrown (id))

(defmacro with-failure-handling-base (clauses &body body)
  "Macro that replaces handler-case in cram-language. This is
necessary because error handling does not work across multiple
threads. When an error is signaled, it is put into an envelope to
avoid invocation of the debugger multiple times. When handling errors,
this envelope must also be taken into account.

We also need a mechanism to retry since errors can be caused by plan
execution and the environment is highly non-deterministic. Therefore,
it is possible to use the function `retry' that is lexically bound
within with-failure-handling-base and causes a re-execution of the body.

When an error is unhandled, it is passed up to the next failure
handling form (exactly like handler-bind). Errors are handled by
invoking the retry function or by doing a non-local exit. Note that
with-failure-handling-base implicitly creates an unnamed block,
i.e. `return' can be used."
  (with-gensyms (wfh-block-name)
    (let* ((clauses
             (loop for clause in clauses
                   if (and (listp (car clause))
                           (eql (caar clause) 'or))
                     appending (loop for case-symbol in (rest (car clause))
                                     collecting (append
                                                 (list case-symbol)
                                                 (cdr clause)))
                   else
                     collecting clause))
           (condition-handler-syms
             (loop for clause in clauses
                   collecting (cons (car clause)
                                    (gensym (symbol-name (car clause)))))))
      `(let ((*retry-path* *current-path*) (log-id (first (cram-language::on-with-failure-handling-begin
                             (list ,@(mapcar (lambda (clause)
                                               (write-to-string (car clause)))
                                             clauses))))))
         (declare (special *retry-path*))
         (unwind-protect
              (block nil
                (tagbody ,wfh-block-name
                   (flet ((retry ()
                            (if (and (boundp *reset-on-retry*) *reset-on-retry*) (clear-tasks (task-tree-node *retry-path*)) nil)
                            (go ,wfh-block-name)))
                     (declare (ignorable (function retry)))
                     (flet ,(mapcar (lambda (clause)
                                      (destructuring-bind (condition-name lambda-list &rest body)
                                          clause
                                        `(,(cdr (assoc condition-name condition-handler-syms))
                                          ,lambda-list
                                          ,@body)))
                             clauses)
                       (handler-bind
                           ((common-lisp-error-envelope
                              (lambda (condition)
                                (typecase (envelop-error condition)
                                  ,@(mapcar (lambda (err-def)
                                              `(,(car err-def)
                                                (,(cdr err-def) (envelop-error condition))))
                                     condition-handler-syms))))
                            ,@(mapcar (lambda (clause)
                                        `(,(car clause)
                                          (lambda (f)
                                            (cram-language::on-with-failure-handling-handled log-id)
                                            (let ((rethrown nil))
                                              (unwind-protect
                                                   (prog1
                                                       (funcall
                                                        #',(cdr (assoc (car clause)
                                                                       condition-handler-syms)) f)
                                                     (setf rethrown t))
                                                (when rethrown
                                                  (cram-language::on-with-failure-handling-rethrown log-id)))))))
                                      clauses))
                         (return (progn ,@body)))))))
           (cram-language::on-with-failure-handling-end log-id))))))

(defmacro with-failure-handling (clauses &body body)
  "Macro that replaces handler-case in cram-language. This is
necessary because error handling does not work across multiple
threads. When an error is signaled, it is put into an envelope to
avoid invocation of the debugger multiple times. When handling errors,
this envelope must also be taken into account.

We also need a mechanism to retry since errors can be caused by plan
execution and the environment is highly non-deterministic. Therefore,
it is possible to use the function `retry' that is lexically bound
within with-failure-handling and causes a re-execution of the body.

When an error is unhandled, it is passed up to the next failure
handling form (exactly like handler-bind). Errors are handled by
invoking the retry function or by doing a non-local exit. Note that
with-failure-handling implicitly creates an unnamed block,
i.e. `return' can be used.

NOTE: currently calls with-failure-handling-base with *reset-on-retry* set to nil.
This is the default CRAM behavior: retry will simply run the body again, and leave
the task tree intact."
  `(let ((*reset-on-retry* nil))
     (declare (special *reset-on-retry*))
     (with-failure-handling-base ,clauses ,@body)))

(defmacro with-transformative-failure-handling (clauses &body body)
  "Version of with-failure-handling that enables plan transformation as a means of error handling. 
See with-failure-handling for the CRAM basic approach to failure handling and its reasons.

NOTE: calls with-failure-handling-base with *reset-on-retry* set to T.
This is the only difference to the with-failure-handling case, and results
in the task tree resetting from the node corresponding to body downwards
to the leaves. The clauses are assumed to transform the plan in order to
handle failure; the task tree reset is so that the transformations are
guaranteed to be run."
  `(let ((*reset-on-retry* T))
     (declare (special *reset-on-retry*))
     (with-failure-handling-base ,clauses ,@body)))

(defmacro with-retry-counters (counter-definitions &body body)
  "Lexically binds all counters in `counter-definitions' to the intial
  values specified in `counter-definitions'. `counter-definitions' is
  similar to `let' forms with the difference that the counters will
  not be available under the specified names in the lexical
  environment established by this macro. In addition, the macro
  defines the local macro \(DO-RETRY <counter> <body-form>*\) to
  decrement the counter and execute code when the maximal retry count
  hasn't been reached yet and the function `\(RESET-COUNTER
  <counter>\)."
  (let ((counters (mapcar (lambda (definition)
                            (let ((name (car definition)))
                              (cons name (gensym (symbol-name name)))))
                          counter-definitions)))
    `(let ,(mapcar (lambda (counter)
                     (list (cdr counter)
                           (second (assoc (car counter) counter-definitions))))
            counters)
       (macrolet ((do-retry (counter &body body)
                    (let ((counter-name (cdr (assoc counter ',counters))))
                      `(when (> ,counter-name 0)
                         (decf ,counter-name)
                         ,@body)))
                  (get-counter (counter)
                    `,(cdr (assoc counter ',counters)))
                  (reset-counter (counter)
                    `(setf ,(cdr (assoc counter ',counters))
                           ,(second (assoc counter ',counter-definitions)))))
         ,@body))))
