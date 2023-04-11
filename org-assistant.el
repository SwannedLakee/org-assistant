;;; org-assistant.el --- Org babel extension for Chat Assistant APIs -*- lexical-binding: t -*-

;; Author: Tyler Dodge (tyler@tdodge.consulting)
;; Version: 0.1
;; Keywords: convenience
;; Package-Requires: ((emacs "26.1") (uuid "0.0.3") (deferred "0.5.1") (s "1.12.0") (dash "2.19.1"))
;; URL: https://github.com/tyler-dodge/org-assistant
;; Git-Repository: git://github.com/tyler-dodge/org-assistant.git
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;;
;;;
;;; Commentary:
;; org-assistant provides support for accessing chat APIs such as ChatGPT in the context of an org
;; notebook.
;; It provides a function named org-assistant that serves as entrypoint for displaying an org assistant buffer.
;; Also, it can be used in any org file by using a src block like #+BEGIN_SRC assistant or #+BEGIN_SRC ?.
;;
;; The API Key is looked up via org-assistant-auth-function, which has meen tested using the MacOS Keychain.
;; Alternatively, org-assistant-auth-function can be a string and directly set to your API key.
;;
;; org-assistant uses the org tree in order to generate the message list whenever sending information to the chat endpoint.
;; It will only use messages from the branch of the tree that the block that initiated the request is in.  It does not include
;; example blocks or source blocks that appear later in the org buffer than the initiating block.
;; Example blocks are treated as being responses from the assistant by default if they occur after user messages.
;; If the example block is before any user source block, they are treated as system messages to the assistant instead.
;;
;; ### Example
;; <example>
;; * User Question
;; #+BEGIN_SRC ?
;; Hi
;; #+END_SRC
;;
;; AI Response
;; #+BEGIN_EXAMPLE
;; Hello! How can I assist you today?
;; #+END_EXAMPLE
;; </example>
;;; Code:

(require 'org)
(require 'deferred)
(require 's)
(require 'uuid)
(require 'dash)

(defgroup org-assistant nil "Customization settings for `org-assistant'."
  :group 'org)

(defcustom org-assistant-auth-function #'org-assistant-auth-source-search
  "Function used to get the secret key.
Optionally can be set directly to a string, in which case it will be
used as the OpenAI key."
  :group 'org-assistant
  :type '(string function))

(defcustom org-assistant-buffer-name "*org-assistant*"
  "The buffer name used for the `org-assistant' buffer."
  :group 'org-assistant
  :type '(string))

(defcustom org-assistant-model "gpt-3.5-turbo"
  "The model used for the assistant."
  :group 'org-assistant
  :type '(string))

(defcustom org-assistant-endpoint "https://api.openai.com/v1/chat/completions"
  "The endpoint used for the assistant."
  :group 'org-assistant
  :type '(string))

(defvar org-babel-default-header-args:assistant
  (list (cons :results "raw"))
  "Extra args so that org babel renders the results correctly.
This should match `org-babel-default-header-args:?'")

(defvar org-babel-default-header-args:?
  org-babel-default-header-args:assistant
  "Extra args so that org babel renders the results correctly.
This should match `org-babel-default-header-args:assistant'")

(defvar org-assistant-history nil
  "History variable for `org-assistant'.")

(defun org-assistant-with-initial-message (message)
  "Create and display a buffer named `org-assistant-buffer-name'.

The buffer contains the response from the assistant given the prompt
contained in MESSAGE."
  (let ((buffer (get-buffer-create "*org-assistant*")))
    (with-current-buffer buffer
      (org-mode)
      (org-assistant-mode 1)
      (display-line-numbers-mode -1)
      (goto-char (point-max))
      (insert (format "\n* Question\n#+BEGIN_SRC ?\n%s\n#+END_SRC\n"
                      message))
      (run-at-time nil nil
                   (lambda ()
                     (with-current-buffer buffer
                       (goto-char (point-max))
                       (forward-line -1)
                       (org-ctrl-c-ctrl-c)
                       (cl-loop for window in (get-buffer-window-list buffer)
                                do (set-window-start window (point-max)))))))
    (select-window (display-buffer buffer))))

(defvar org-assistant-mode-map (make-sparse-keymap)
  "Keymap for `org-assistant-mode' buffers.")

(define-minor-mode org-assistant-mode "Mode for org assistant buffers."
  :init-value nil
  :keymap org-assistant-mode-map)

;;;###autoload
(defun org-assistant ()
  "Prompt the user for an initial prompt for the assistant.

Then display a window with the buffer containing the response."
  (interactive)
  (let ((message (read-from-minibuffer "Chat:" nil nil nil org-assistant-history)))
    (org-assistant-with-initial-message message)))

(defun org-assistant-auth-source-search ()
  "Example auth source function for use with `org-assistant-auth-function'.

This has been tested with the `macos-keychain-generic' auth-source
where openai-key is an application password with the name openai-key."
  (-some-->
      (auth-source-search
       :user "openai-key")
    (car it)
    (plist-get it :secret)
    (aref it 2)
    (aref it 0)))

(defun org-assistant-execute (blocks)
  "Sends the list of BLOCKS t' the `org-assistant-endpoint' to get a response.

BLOCKS is a list of cons cells: where the car of the cell
is either `user' or `assistant'.  The cdr of the cell is the message
corresponding to the sender.

The list of BLOCKS should be in chronological order, with the first
being the earliest message.  Returns a deferred object representing
the json response from the endpoint."
  (deferred:$
   (let
       ((url-request-method "POST")
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer "
                                       (if (stringp org-assistant-auth-function)
                                           org-assistant-auth-function
                                         (funcall org-assistant-auth-function))))
           ("Content-Type" . "application/json")))
        (url-request-data (let ((json-object-type 'alist)
                                (json-key-type 'string)
                                (json-array-type 'vector))
                     (json-encode
                      `(("model" . ,org-assistant-model)
                        ("messages" . ,(->> blocks
                                            (--map (list
                                                    (cons "content" (cdr it))
                                                    (cons "role" (symbol-name (car it)))))
                                            (vconcat))))))))
     (deferred:url-retrieve org-assistant-endpoint))
   (deferred:nextc it (lambda (buffer)
                        (with-current-buffer buffer
                          (goto-char (point-min))
                          (re-search-forward (rx line-start eol) nil t)
                          (json-read))))))

(defmacro org-assistant-org-babel-async-response (&rest prog)
  "Macro for handling asynchronous responses with `org-mode'.

Provides a function called `babel-response' that can be called in PROG to
substitute the response value in the org buffer that initiated this call.

Returns a UUID placeholder that `org-mode' emits into the buffer, which is
later substituted by `org-assistant'."
  (declare
   (debug t)
   (indent 0))
  (let ((buffer-var (make-symbol "buffer"))
        (insert-prompt-var (make-symbol "insert-prompt"))
        (replacement-var (make-symbol "replacement")))
    `(progn
       (let* ((,buffer-var (current-buffer))
              (,replacement-var (uuid-string)))
         (cl-flet ((babel-response (message)
                     (run-at-time
                      nil nil
                      (lambda ()
                        (let ((inhibit-message t))
                          (with-current-buffer ,buffer-var
                            (-some-->
                                (save-mark-and-excursion
                                  (goto-char (point-min))
                                  (when (re-search-forward (rx (literal ,replacement-var))
                                                           nil t)
                                    (let ((,insert-prompt-var (not (save-mark-and-excursion
                                                                     (re-search-forward (rx
                                                                                         "#+BEGIN_SRC"
                                                                                         (+ whitespace)
                                                                                         (or "assistant" "?")) nil t)))))
                                      (save-excursion
                                        (replace-match (format "#+BEGIN_EXAMPLE
%s
#+END_EXAMPLE%s" message (if ,insert-prompt-var "\n\n#+BEGIN_SRC ?\n\n#+END_SRC\n" "")) nil t))
                                      (when ,insert-prompt-var (re-search-backward (rx "#+BEGIN_SRC"))
                                            (forward-line 1)
                                            (point)))))
                              (progn (goto-char it)
                                     (cl-loop for window in (get-buffer-window-list (current-buffer))
                                              do (set-window-point window it))))))))))
           ,@prog)
         ,replacement-var))))

;;;###autoload
(defun org-babel-execute:assistant (_ _)
  "Execute an `org-assistant' in an org-babel context.

This is intended to be called via org babel in a src block with Ctrl-C
Ctrl-C like:

<example>
#+BEGIN_SRC assistant
Hi
#+END_SRC
</example>

The response from the assistant will be in the example block
following:

<example>
#+BEGIN_EXAMPLE
Response
#+END_EXAMPLE
</example>

All of the messages that are in the same branch of the org tree are
included in the request to the assistant.
<example>
* Question
#+BEGIN_SRC assistant
Hi
#+END_SRC

#+BEGIN_EXAMPLE
Response
#+END_EXAMPLE

#+BEGIN_SRC assistant
What's up?
#+END_SRC
</example>

Running babel on the second assistant block will send the
conversation:

<example>
User: Hi
Assistant: Response
User: What's up?
</example>

Running babel on the first assistant block will only include the
messages before it:

<example>
User: Hi
</example>

Only messages in the same branch will be included:

<example>
* Question
#+BEGIN_SRC assistant
Hi
#+END_SRC

#+BEGIN_EXAMPLE
Response
#+END_EXAMPLE
** Branch A
#+BEGIN_SRC assistant
Branch A
#+END_SRC

#+BEGIN_EXAMPLE
Branch A Response
#+END_EXAMPLE

** Branch B
#+BEGIN_SRC assistant
Branch B
#+END_SRC

#+BEGIN_EXAMPLE
Branch B Response
#+END_EXAMPLE
</example>
If you ran Ctrl-C Ctrl-C on Branch B's src block the conversation sent
to the endpoint would be:

<example>
User: Hi
Assistant: Response
User: Branch B
Assistant: Branch B Response
</example>"
  (let ((blocks (org-assistant--org-blocks)))
        (org-assistant-org-babel-async-response
         (deferred:$
          (org-assistant-execute blocks)
          (deferred:nextc
           it
           (lambda (response)
             (cl-loop for choice across (alist-get 'choices response)
                      collect
                      (-some-->
                          (->> choice
                               (alist-get 'message)
                               (alist-get 'content))
                        (string-fill it 80)))))
          (deferred:nextc it (lambda (response)
                               (babel-response (s-join "" response))))))))

;;;###autoload
(defalias #'org-babel-execute:? #'org-babel-execute:assistant)

(defun org-assistant--org-blocks ()
  "Return a list of the blocks between point and the top heading of the tree.

Only blocks that are within the top level section of each heading will
be included, so subheadings can represent multiple paths of the
conversation."
  (save-mark-and-excursion
    (when (org-in-src-block-p)
      (forward-line 0)
      (search-forward "#+END_SRC"))
    (when (org-in-block-p (list "EXAMPLE"))
      (search-forward "#+END_EXAMPLE"))
    (let ((start-pt (point)))
      (cl-loop
       with has-prompt = nil
       for block in
       (reverse
        (cl-loop
         with first = t
         while (if first
                   (prog1 t
                     (org-previous-visible-heading 1)
                     (forward-line 0)
                     (setq first nil))
                 (org-up-heading-safe))
         append
         (-let [(range-start range-end) (list
                                         (point)
                                         (save-excursion
                                           (org-next-visible-heading 1)
                                           (point)))]
           (goto-char range-start)
           (save-excursion
             (reverse
              (cl-loop
               while (re-search-forward (rx (or (regexp org-babel-src-block-regexp)
                                                (regexp (rx "#+BEGIN_EXAMPLE"
                                                            (* anything)
                                                            "#+END_EXAMPLE"))))
                                        (min start-pt range-end) t)
               collect (progn
                         (let* ((match-start (match-beginning 0))
                                (match-end (match-end 0))
                                (message-type
                                 (progn
                                   (goto-char match-start)
                                   (let ((line (thing-at-point 'line)))
                                     (if (s-contains-p "BEGIN_EXAMPLE" line)
                                         (if (save-excursion
                                               (forward-line -1)
                                               (s-contains-p "#+SYSTEM" (thing-at-point 'line)))
                                             'system
                                           'assistant) 'user)))))
                           (forward-line 1)
                           (cons message-type
                                 (buffer-substring-no-properties
                                  (point)
                                  (save-excursion (goto-char match-end)
                                                  (forward-line 0)
                                                  (point))))))))))))
       collect
       (if has-prompt
           block
           (if (eq (car block) 'user)
               (prog1 block
                 (setq has-prompt t))
             (cons 'system (cdr block))))))))

;;;###autoload
(defun org-assistant-explain-function ()
  "Ask the assistant to explain the function at point."
  (interactive)
  (org-assistant-with-initial-message (concat (thing-at-point 'defun) "\nExplain this function for me")))

;;;###autoload
(defun org-assistant-write-docstring ()
  "Ask the assistant to generate a docstring for the function at point."
  (interactive)
  (org-assistant-with-initial-message (concat (thing-at-point 'defun) "\nWrite a concise docstring for me")))

(provide 'org-assistant)
;;; org-assistant.el ends here
