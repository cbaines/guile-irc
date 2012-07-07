;; Copyright (C) 2012 bas smit (fbs)

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Lesser General Public License for more details.

;; You should have received a copy of the GNU Lesser General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

;; with some help with dsmith from #guile

(define-module (irc message)
  #:version (0 1)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (ice-9 rdelim)
  #:use-module ((srfi srfi-1)
		#:select (every any))
  #:export (command
	    middle
	    trailing
	    raw
	    time
	    prefix
	    is-channel?
	    parse-target
	    parse-source
	    make-message
	    parse-message-string))

;; <message> ::=
;;     [':' <prefix> <SPACE> ] <command> <params> <crlf>
;; <prefix> ::=
;;     <servername> | <nick> [ '!' <user> ] [ '@' <host> ]
;; <command> ::=
;;     <letter> { <letter> } | <number> <number> <number>
;; <SPACE> ::=
;;     ' ' { ' ' }
;; <params> ::=
;;     <SPACE> [ ':' <trailing> | <middle> <params> ]
;; <middle> ::=
;;     <Any *non-empty* sequence of octets not including SPACE or NUL or CR or LF, the first of which may not be ':'>
;; <trailing> ::=
;;     <Any, possibly *empty*, sequence of octets not including NUL or CR or LF>
;; <crlf> ::=
;;     CR LF

;;; internal

(define prefix-object
  (make-record-type "irc:message:prefix"
		    '(nick user hostname server raw)
		    (lambda (obj port) (display "#<irc:message:prefix>" port))))

(define message-object
  (make-record-type "irc:message"
		    '(prefix command middle trailing time raw)
		    (lambda (obj port) (display "#<irc:message>" port))))

(define message?  (record-predicate message-object))
(define m:prefix? (record-predicate prefix-object))

(define m:prefix	 (record-accessor message-object 'prefix))

(define p:nick		 (record-accessor prefix-object 'nick))
(define p:user		 (record-accessor prefix-object 'user))
(define p:hostname	 (record-accessor prefix-object 'hostname))
(define p:server	 (record-accessor prefix-object 'server))
(define p:raw		 (record-accessor prefix-object 'raw))

(define (m:p:nick msg)		(p:nick (m:prefix msg)))
(define (m:p:user msg)		(p:user (m:prefix msg)))
(define (m:p:hostname msg)	(p:hostname (m:prefix msg)))
(define (m:p:server msg)	(p:server (m:prefix msg)))
(define (m:p:raw msg)		(p:raw (m:prefix msg)))

(define* (make-message-object #:key prefix command middle trailing raw time)
  ((record-constructor message-object)
   prefix
   command
   middle
   trailing
   time
   raw))

(define* (make-prefix-object #:key nick user hostname server raw)
  ((record-constructor prefix-object)
   nick user hostname server raw))

(define (parse-prefix str)
  (if (string-contains str "!")
      (let ([!loc (string-index str #\!)]
	    [@loc (string-index str #\@)])
	(make-prefix-object
	 #:nick (substring str 0 !loc)
	 #:user (substring str (+ 1 !loc) @loc)
	 #:hostname (substring str (+ 1 @loc))
	 #:raw str))
      (make-prefix-object
       #:server str
       #:raw str)))

(define channel-prefixes '(#\# #\& #\! #\+))

(define (symbolize cmd)
  (if (char-numeric? (string-ref cmd 0))
      (string->number cmd)
      (string->symbol (string-upcase cmd))))

;; external

(define (parse-message-string msg)
  "Parse irc message string `msg' and return an irc-message-object."
  (define rx1 (make-regexp "^(:([^ ]+) +)?([^ ]+) +(.+)$"))
  (define rx2 (make-regexp "^([^:]*):?(.+)?$"))
  (define (flatten list)
    (if (= (length list) 1)
	(car list)
	list))
  (catch #t
    (lambda ()
      (let* ([m1 (regexp-exec rx1 msg)]
	     [m2 (regexp-exec rx2 (match:substring m1 4))])
	(make-message-object
	 #:prefix (parse-prefix (match:substring m1 2))
	 #:command (symbolize (match:substring m1 3))
	 #:middle (flatten (delete #f (string-tokenize (match:substring m2 1))))
	 #:trailing (match:substring m2 2)
	 #:time (current-time)
	 #:raw  msg)))
    (lambda (key . args) #f)))

(define* (make-message #:key command middle trailing)
  "Create a new irc message.
Command: string or number.
middle: string or list of strings.
trailing: string."
  (define (typecheck-list pred lst)
    (every pred list))
  (define (check-command cmd)
    (cond
     ((string? cmd) (string->symbol (string-upcase cmd)))
     ((or (number? cmd)
	  (symbol? cmd)) cmd)
     (else (throw 'irc-message-error))))
  (define (check-middle middle)
    (cond 
     ((and (list? middle)
	   (typecheck-list string? middle)) (throw 'irc-message-error))
     ((string? middle) middle)
     (else (throw 'irc-message-error))))
  (define (check-trailing trail)
    (if (and trail (not (string? trail)))
	(throw 'irc-message-error)
	trail))
  (let ([cmd (check-command command)]
	[middle (check-middle middle)]
	[trailing (check-trailing trailing)])    
    (make-message-object
     #:command command
     #:middle middle
     #:trailing trailing)))

(define (parse-source msg)
  "Find out who send the irc-message."
  (if (message? msg)
      (if (m:p:server msg)
	  (m:p:server msg)
	  (m:p:user msg))
      #f))

(define (parse-target msg)
  "Find out who to send a reply to. Note that this only works for PRIVMSG and
 PING commands, other commands don't allow a responce."
  (if (message? msg)
      (let ([cmd (command msg)]
	    [middle (middle msg)])
	(cond ((eq? command msg 'PING) (middle msg))
	      ((eq? command msg 'PRIVMSG)
	       (if (is-channel? (middle msg))
		   (middle msg)
		   (p:user msg)))
	      (else #f)))
      #f))

(define (is-channel? str)
  "Return #t is string `str' is a valid channel, #f otherwise."
  (let ([c (string-ref string 0)])
    (->bool (memq c channel-prefixes))))

(define (command msg)
  "Return the command. This is either a symbol or a number."
  ((record-accessor message-object 'command) msg))

(define (middle msg)
  "Return `middle' of the message. This is either a list of strings or
 a string if there is only one middle."
  ((record-accessor message-object 'middle) msg))

(define (trailing msg)
  "Return the trailing part of the message if there is one, #f otherwise."
  ((record-accessor message-object 'trailing) msg))

(define (raw msg)
  "Return the unparsed message string. Note that this only works for messages
 constructed useing parse-message-string."
  ((record-accessor message-object 'raw) msg))

(define (time msg)
  "Return the message timestamp (moment at which it was parsed). Time format
 is seconds since epoch."
  ((record-accessor message-object 'time) msg))

(define (prefix msg)
  "Return the prefix of irc-message `msg'. If the message was send by as server
 the returnvalue is a string. If the message was send by a user the returnvalue
 is a list of strings: '(nick user host)."
  (if (m:p:nick msg)
      (list (m:p:nick msg) (m:p:user msg) (m:p:hostname msg))
      (m:p:server msg)))
