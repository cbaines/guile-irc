;; Copyright (C) 2012, 2013 bas smit (fbs)
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.

(define-module (irc network)
  #:version (0 3 0)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (ice-9 rdelim)
  #:use-module ((irc gnutls) #:renamer (symbol-prefix-proc 'tls:))
  #:export (
            create
            (do-connect . connect)
            send
            receive
            data-ready?
            close/cleanup
            get-socket
            connected?
            ssl?
            ))

;; Types

(define-record-type <network>
  (make-network
   address
   port
   socket
   addrinfo
   ssl
   loghook
   connected?)
  network?
  (address get-address set-address!)
  (port get-port set-port!)
  (socket get-socket set-socket!)
  (addrinfo get-addrinfo set-addrinfo!)
  (ssl get-ssl set-ssl!)
  (loghook get-loghook set-loghook!)
  (connected? connected? set-connected?!))

(set-record-type-printer!
 <network>
 (lambda (record port)
   (write-char #\< port)
   (display "network: ")
   (display (get-address record) port)
   (if (get-ssl record) (display "/ssl") port)
   (if (connected? record)
       (display "!>" port)
       (display "?>" port))))

(define (ssl? obj)
  (->bool (get-ssl obj)))

;; Private

(define (enable-gnutls-debug)
  (tls:enable-global-logging! 10 #f))

(define (disable-gnutls-debug)
  (tls:disable-global-logging!))

;; Public

(define* (create #:key (address "localhost") (port 6697) (family PF_INET) (ssl #f))
  "Create a new network.
address: Address to connect.
port: port to connect to.
family: Socket family (see manual  7.2.11)
tls: If set to #t use ssl (requires gnutls)"
  (let* ([ai (car (getaddrinfo address "ircd" family))]
         [sock  (socket (addrinfo:fam ai)
                     (addrinfo:socktype ai)
                     (addrinfo:protocol ai))])
    (make-network
     address ;; address
     port    ;; port
     sock    ;; socket
     ai      ;; addrinfo
     (if ssl ;; ssl
         (tls:wrap-ssl sock)
         #f)
     #f      ;; loghook
     #f      ;; connected
     )))


(define (do-connect obj)
  "connect to server"
  (if (not (connected? obj))
      (let ([ai (get-addrinfo obj)])
        (catch #t
          (lambda ()
            (connect (get-socket obj)
                     (addrinfo:fam ai)
                     (sockaddr:addr (addrinfo:addr ai))
                     (get-port obj)))
          (lambda (key . params)
            (network-error "Unable to connect to: ~a.")))
        (if (get-ssl obj)
            (tls:handshake (get-ssl obj)))
        (set-connected?! obj #t))
      #t))

(define (close/cleanup obj)
  "Close the connection and clean the object."
  (if (get-ssl obj)
      (tls:close/cleanup (get-ssl obj)))
  (close (get-socket obj))
  (set-address! obj #f)
  (set-port! obj #f)
  (set-socket! obj #f)
  (set-addrinfo! obj #f)
  (set-ssl! obj #f)
  (set-loghook! obj #f)
  (set-connected?! obj #f)
  #t)
 
(define (send obj msg)
  (if (connected? obj)
      (if (ssl? obj)
          (tls:send (get-ssl obj) msg)
          (display msg (get-socket obj)))))

(define (receive obj)
"Try to read a line (using read-line)."
  (if (connected? obj)
      (let ([msg (if (ssl? obj)
                     (tls:receive (get-ssl obj))
                     (read-line (get-socket obj)))])
        ;; If an eof-object is read the port is closed.
        (if (eof-object? msg)
            (begin
              (close/cleanup obj)
              #f ;;Throw error
              )
            msg))
      ;; TODO: Throw error
      ))

(define (data-ready? obj)
  (if (connected? obj)
      (if (ssl? obj)
          (tls:data-ready? (get-ssl obj))
          (char-ready? (get-socket obj)))
      #f ;; TODO: Throw error
      ))
