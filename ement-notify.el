;;; ement-notify.el --- Notifications for Ement events  -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; Keywords: comm

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

;;; Commentary:

;; This library implements notifications for Ement events.

;;; Code:

;;;; Requirements

(require 'cl-lib)
(require 'map)
(require 'notifications)

(require 'ement-room)

(eval-when-compile
  (require 'ement-structs))

;;;; Variables

(declare-function ement-room-list "ement-room-list")
(defvar ement-notify-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "S-<return>") #'ement-notify-reply)
    (define-key map (kbd "M-g M-l") #'ement-room-list)
    (define-key map (kbd "M-g M-m") #'ement-notify-switch-to-mentions-buffer)
    (define-key map (kbd "M-g M-n") #'ement-notify-switch-to-notifications-buffer)
    (make-composed-keymap (list map button-buffer-map) 'view-mode-map))
  "Map for Ement notification buffers.")

;;;; Customization

(defgroup ement-notify nil
  "Notification options."
  :group 'ement)

(defcustom ement-notify-ignore-predicates
  '(ement-notify--event-not-message-p ement-notify--event-from-session-user-p)
  "Display notification if none of these return non-nil for an event.
Each predicate is called with three arguments: the event, the
room, and the session (each the respective struct)."
  :type '(repeat (choice (function-item ement-notify--event-not-message-p)
                         (function-item ement-notify--event-from-session-user-p)
                         (function :tag "Custom predicate"))))

(defcustom ement-notify-log-predicates
  '(ement-notify--event-mentions-session-user-p
    ement-notify--event-mentions-room-p
    ement-notify--room-buffer-live-p
    ement-notify--room-unread-p)
  "Predicates to determine whether to log an event to the notifications buffer.
If one of these returns non-nil for an event, the event is logged."
  :type 'hook
  :options '(ement-notify--event-mentions-session-user-p
             ement-notify--event-mentions-room-p
             ement-notify--room-buffer-live-p
             ement-notify--room-unread-p))

(defcustom ement-notify-mention-predicates
  '(ement-notify--event-mentions-session-user-p
    ement-notify--event-mentions-room-p)
  "Predicates to determine whether to log an event to the mentions buffer.
If one of these returns non-nil for an event, the event is logged."
  :type 'hook
  :options '(ement-notify--event-mentions-session-user-p
             ement-notify--event-mentions-room-p))

(defcustom ement-notify-notification-predicates
  '(ement-notify--event-mentions-session-user-p
    ement-notify--event-mentions-room-p
    ement-notify--room-buffer-live-p
    ement-notify--room-unread-p)
  "Predicates to determine whether to send a desktop notification.
If one of these returns non-nil for an event, the notification is sent."
  :type 'hook
  :options '(ement-notify--event-mentions-session-user-p
             ement-notify--event-mentions-room-p
             ement-notify--room-buffer-live-p
             ement-notify--room-unread-p))

(defcustom ement-notify-sound nil
  "Sound to play for notifications."
  :type '(choice (file :tag "Sound file")
                 (string :tag "XDG sound name")
                 (const :tag "Default XDG message sound" "message-new-instant")
                 (const :tag "Don't play a sound" nil)))

(defcustom ement-notify-limit-room-name-width 14
  "Limit the width of room display names in mentions and notifications buffers.
This prevents the margin from being made excessively wide."
  :type '(choice (integer :tag "Maximum width")
                 (const :tag "Unlimited width" nil)))

(defcustom ement-notify-prism-background nil
  "Add distinct background color by room to messages in notification buffers.
The color is specific to each room, generated automatically, and
can help distinguish messages by room."
  :type 'boolean)

(defcustom ement-notify-room-avatars t
  "Show room avatars in the notifications buffers.
This shows room avatars at the left of the window margin in
notification buffers.  It's not customizeable beyond that due to
limitations and complexities of displaying strings and images in
margins in Emacs.  But it's useful, anyway."
  :type 'boolean)

;;;; Commands

(declare-function ement-view-room "ement")
(declare-function ement-room-goto-event "ement-room")
(defun ement-notify-button-action (button)
  "Show BUTTON's event in its room buffer."
  ;; TODO: Is `interactive' necessary here?
  (interactive)
  (let* ((session (button-get button 'session))
         (room (button-get button 'room))
         (event (button-get button 'event)))
    (ement-view-room room session)
    (ement-room-goto-event event)))

(defun ement-notify-reply ()
  "Send a reply to event at point."
  (interactive)
  (save-window-excursion
    ;; Not sure why `call-interactively' doesn't work for `push-button' but oh well.
    (push-button)
    (call-interactively #'ement-room-send-reply)))

(defun ement-notify-switch-to-notifications-buffer ()
  "Switch to \"*Ement Notifications*\" buffer."
  (interactive)
  (switch-to-buffer (ement-notify--log-buffer "*Ement Notifications*")))

(defun ement-notify-switch-to-mentions-buffer ()
  "Switch to \"*Ement Mentions*\" buffer."
  (interactive)
  (switch-to-buffer (ement-notify--log-buffer "*Ement Mentions*")))

;;;; Functions

(defun ement-notify (event room session)
  "Send notifications for EVENT in ROOM on SESSION.
Calls functions in `ement-notify-functions' if all of
`ement-notify-ignore-predicates' return nil.  Does not do
anything if session hasn't finished initial sync."
  (when (and (ement-session-has-synced-p session)
             (cl-loop for pred in ement-notify-ignore-predicates
                      never (funcall pred event room session)))
    (when (run-hook-with-args-until-success 'ement-notify-notification-predicates event room session)
      (ement-notify--notifications-notify event room session))
    (when (run-hook-with-args-until-success 'ement-notify-log-predicates event room session)
      (ement-notify--log-to-buffer event room session))
    (when (run-hook-with-args-until-success 'ement-notify-mention-predicates event room session)
      (ement-notify--log-to-buffer event room session :buffer-name "*Ement Mentions*"))))

(defun ement-notify--notifications-notify (event room _session)
  "Call `notifications-notify' for EVENT in ROOM on SESSION."
  (pcase-let* (((cl-struct ement-event sender content) event)
               ((cl-struct ement-room avatar) room)
               ((map body) content)
               (room-name (ement-room-display-name room))
               (sender-name (ement-room--user-display-name sender room))
               (title (format "%s in %s" sender-name room-name)))
    ;; TODO: Encode HTML entities.
    (when (stringp body)
      ;; If event has no body, it was probably redacted or something, so don't notify.
      (truncate-string-to-width body 60)
      (notifications-notify :title title :body body
                            :app-name "Ement.el"
                            :app-icon (when avatar
                                        (ement-notify--temp-file
                                         (plist-get (cdr (get-text-property 0 'display avatar)) :data)))
                            :category "im.received"
                            :timeout 5000
                            ;; FIXME: Using :sound-file seems to do nothing, ever.  Maybe a bug in notifications-notify?
                            :sound-file (when (and ement-notify-sound
                                                   (file-name-absolute-p ement-notify-sound))
                                          ement-notify-sound)
                            :sound-name (when (and ement-notify-sound
                                                   (not (file-name-absolute-p ement-notify-sound)))
                                          ement-notify-sound)
                            ;; TODO: Show when action used.
                            ;; :actions '("default" "Show")
                            ;; :on-action #'ement-notify-show
                            ))))

(cl-defun ement-notify--temp-file (content &key (timeout 5))
  "Return a filename holding CONTENT, and delete it after TIMEOUT seconds."
  (let ((filename (make-temp-file "ement-notify--temp-file-"))
        (coding-system-for-write 'no-conversion))
    (with-temp-file filename
      (insert content))
    (run-at-time timeout nil (lambda ()
                               (delete-file filename)))
    filename))

(cl-defun ement-notify--log-to-buffer (event room session &key (buffer-name "*Ement Notifications*"))
  "Log EVENT in ROOM to \"*Ement Notifications*\" buffer."
  ;; HACK: We only log "m.room.message" events for now.  This shouldn't be necessary since we
  ;; have `ement-notify--event-message-p' in `ement-notify-predicates', but just to be safe...
  (when (equal "m.room.message" (ement-event-type event))
    ;; HACK: For now, we call `ement-room--format-message' in a buffer that pretends to be
    ;; the room's buffer.  We have to do this, because the room might not have a buffer yet.
    (with-temp-buffer
      ;; Set these buffer-local variables, which `ement-room--format-message' uses.
      (setf ement-session session
            ement-room room)
      (let* (;; Bind this to nil to prevent `ement-room--format-message' from padding sender name.
             (ement-room-sender-in-headers t)
             ;; NOTE: We hard-code the room and sender name to be in the left
             ;; margin.  It works well.  See also `room-avatar-string' below.
             (ement-room-message-format-spec "%O %S%L%B%R%t")
             (message (ement-room--format-event event room session))
             (buffer (ement-notify--log-buffer buffer-name))
             (avatar-width (if ement-notify-room-avatars 2 0))
             (room-name-width (if ement-notify-limit-room-name-width
                                  (min (+ avatar-width (string-width (ement-room-display-name room)))
                                       ement-notify-limit-room-name-width)
                                (+ avatar-width (string-width (ement-room-display-name room)))))
             (sender-name-width (string-width (ement-room--user-display-name (ement-event-sender event) room)))
             (new-left-margin-width
              (max (buffer-local-value 'left-margin-width buffer)
                   (+ room-name-width sender-name-width 2)))
             (inhibit-read-only t)
             (room-avatar-string
              ;; HACK: This is awkward, but displaying images in the margin along with other non-image text
              ;; requires some hackery due to manipulating and combining the display property.  The root problem is
              ;; that recursive display specs are not supported by Emacs, so if a string in a display spec has its
              ;; own display spec that is an image, the image isn't displayed.  So we have to do things like this.
              (or (when-let* (ement-notify-room-avatars
                              (room-list-avatar (alist-get 'room-list-avatar (ement-room-local room)))
                              (avatar-image (get-text-property 0 'display room-list-avatar)))
                    (propertize " " 'display `((margin left-margin) ,avatar-image)))
                  "")))
        (when ement-notify-prism-background
          (add-face-text-property 0 (length message) (list :background (ement-notify--room-background-color room))
                                  nil message))
        (with-current-buffer buffer
          (save-excursion
            (goto-char (point-max))
            ;; We make the button manually to avoid overriding the message faces.
            ;; TODO: Define our own button type?  Maybe integrating the hack below...
            (save-excursion
              (insert room-avatar-string
                      (propertize message
                                  'button '(t)
                                  'category 'default-button
                                  'action #'ement-notify-button-action
                                  'session session
                                  'room room
                                  'event event)
                      "\n"))
            ;; HACK: Try to remove `button' face property from new text.  (It works!)
            ;; TODO: Use new `ement--remove-face-property' function.
            (cl-loop for next-face-change-pos = (next-single-property-change (point) 'face)
                     for face-at = (get-text-property (point) 'face)
                     when (pcase face-at
                            ('button t)
                            ((pred listp) (member 'button face-at)))
                     do (put-text-property (point) (or next-face-change-pos (point-max))
                                           'face (pcase face-at
                                                   ('button nil)
                                                   ((pred listp) (delete 'button face-at))))
                     while next-face-change-pos
                     do (goto-char next-face-change-pos)))
          (setf left-margin-width new-left-margin-width)
          (when-let (window (get-buffer-window buffer))
            (set-window-margins window new-left-margin-width right-margin-width)))))))

(defun ement-notify--log-buffer (name)
  "Return an Ement notifications buffer named NAME."
  (or (get-buffer name)
      (with-current-buffer (get-buffer-create name)
        (view-mode)
        (visual-line-mode)
        (use-local-map ement-notify-map)
        (setf left-margin-width ement-room-left-margin-width
              right-margin-width 8)
        (current-buffer))))

(defun ement-notify--room-background-color (room)
  "Return a background color on which to display ROOM's messages."
  ;; Based on `ement-room--user-color', hacked up a bit (adjusting
  ;; some of the numbers feels a little like magic).
  (cl-labels ((relative-luminance
               ;; Copy of `modus-themes-wcag-formula', an elegant
               ;; implementation by Protesilaos Stavrou.  Also see
               ;; <https://en.wikipedia.org/wiki/Relative_luminance> and
               ;; <https://www.w3.org/TR/WCAG20/#relativeluminancedef>.
               (rgb) (cl-loop for k in '(0.2126 0.7152 0.0722)
                              for x in rgb
                              sum (* k (if (<= x 0.03928)
                                           (/ x 12.92)
                                         (expt (/ (+ x 0.055) 1.055) 2.4)))))
              (contrast-ratio
               ;; Copy of `modus-themes-contrast'; see above.
               (a b) (let ((ct (/ (+ (relative-luminance a) 0.05)
                                  (+ (relative-luminance b) 0.05))))
                       (max ct (/ ct)))))
    (let* ((id (ement-room-display-name room))
           (id-hash (float (abs (sxhash id))))
	   (ratio (/ id-hash (float (expt 2 24))))
           (color-num (round (* (* 255 255 255) ratio)))
           (color-rgb (list (/ (float (logand color-num 255)) 255)
                            (/ (float (lsh (logand color-num 65280) -8)) 255)
                            (/ (float (lsh (logand color-num 16711680) -16)) 255)))
           (background-rgb (color-name-to-rgb (face-background 'default))))
      (if (> (contrast-ratio color-rgb background-rgb) 2)
          (progn
            ;; Contrast ratio too high: I don't know the best way to fix this, but we
            ;; use a color from a gradient between the computed color and the default
            ;; background color, which seems to blend decently with the background.
            (apply #'color-rgb-to-hex
                   (append (nth 3 (color-gradient background-rgb color-rgb 20))
                           (list 2))))
        (apply #'color-rgb-to-hex (append color-rgb (list 2)))))))

;;;;; Predicates

(defun ement-notify--event-mentions-session-user-p (event room session)
  "Return non-nil if EVENT in ROOM mentions SESSION's user.
If EVENT's sender is SESSION's user, returns nil."
  (pcase-let* (((cl-struct ement-session user) session)
               ((cl-struct ement-event sender) event))
    (unless (equal (ement-user-id user) (ement-user-id sender))
      (ement-room--event-mentions-user-p event user room))))

(defun ement-notify--room-buffer-live-p (_event room _session)
  "Return non-nil if ROOM has a live buffer."
  (buffer-live-p (alist-get 'buffer (ement-room-local room))))

(defun ement-notify--room-unread-p (_event room _session)
  "Return non-nil if ROOM has unread notifications.
According to the room's notification configuration on the server."
  (pcase-let* (((cl-struct ement-room unread-notifications) room)
               ((map notification_count highlight_count) unread-notifications))
    (not (and (equal 0 notification_count)
              (equal 0 highlight_count)))))

(defun ement-notify--event-message-p (event _room _session)
  "Return non-nil if EVENT is an \"m.room.message\" event."
  (equal "m.room.message" (ement-event-type event)))

(defun ement-notify--event-not-message-p (event _room _session)
  "Return non-nil if EVENT is not an \"m.room.message\" event."
  (not (equal "m.room.message" (ement-event-type event))))

(defun ement-notify--event-from-session-user-p (event _room session)
  "Return non-nil if EVENT is sent by SESSION's user."
  (equal (ement-user-id (ement-session-user session))
         (ement-user-id (ement-event-sender event))))

(defun ement-notify--event-mentions-room-p (event _room _session)
  "Return non-nil if EVENT is sent by SESSION's user."
  (pcase-let (((cl-struct ement-event (content (map body))) event))
    (when body
      (string-match-p (rx bow "@room" (or ":" (1+ blank))) body))))

;;;; Footer

(provide 'ement-notify)

;;; ement-notify.el ends here
