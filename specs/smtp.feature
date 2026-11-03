Feature: Sending email over SMTP
  `src/smtp.agc` sends a message with `Smtp.send`, or several on one connection. The specs run it against a small SMTP
  server (fixtures/smtp_peer.agc) on 127.0.0.1 and a free port, which writes down what it received, and so they check
  the dialogue on the wire. STARTTLS and implicit TLS use the test certificate in fixtures/tls (the client trusts its
  CA). An error that comes from a reply of the server has its code (`error_code`), and one that does not is a failure
  of the connection or of the message.

  Scenario: A plain text message goes through MAIL FROM, RCPT TO and DATA, and the client says QUIT
    Given the SMTP server speaks "plain"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send succeeds
    And the server transcript is:
      """
      S: 220 peer.test ready
      C: EHLO client.test
      S: 250 peer.test
      C: MAIL FROM:<ana@example.com>
      S: 250 sender ok
      C: RCPT TO:<bob@example.com>
      S: 250 recipient ok
      C: DATA
      S: 354 end data with a dot
      C: Date: Tue, 03 Nov 2026 10:55:02 +0000
      C: From: ana@example.com
      C: To: bob@example.com
      C: Subject: Hello
      C: Message-ID: <spec@example.com>
      C: MIME-Version: 1.0
      C: Content-Type: text/plain; charset=utf-8
      C: Content-Transfer-Encoding: 7bit
      C:
      C: Hi Bob.
      C: .
      S: 250 queued as 1
      C: QUIT
      S: 221 bye
      """

  Scenario: STARTTLS comes before the login, and EHLO is said again once the connection is encrypted
    Given the SMTP server speaks "starttls"
    And the SMTP server offers AUTH "PLAIN LOGIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "secret"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send succeeds
    And the server transcript is:
      """
      S: 220 peer.test ready
      C: EHLO client.test
      S: 250-peer.test
      S: 250-STARTTLS
      S: 250 AUTH PLAIN LOGIN
      C: STARTTLS
      S: 220 ready to start TLS
      C: EHLO client.test
      S: 250-peer.test
      S: 250-STARTTLS
      S: 250 AUTH PLAIN LOGIN
      C: AUTH PLAIN AGFuYQBzZWNyZXQ=
      S: 235 2.7.0 authenticated
      C: MAIL FROM:<ana@example.com>
      S: 250 sender ok
      C: RCPT TO:<bob@example.com>
      S: 250 recipient ok
      C: DATA
      S: 354 end data with a dot
      C: Date: Tue, 03 Nov 2026 10:55:02 +0000
      C: From: ana@example.com
      C: To: bob@example.com
      C: Subject: Hello
      C: Message-ID: <spec@example.com>
      C: MIME-Version: 1.0
      C: Content-Type: text/plain; charset=utf-8
      C: Content-Transfer-Encoding: 7bit
      C:
      C: Hi Bob.
      C: .
      S: 250 queued as 1
      C: QUIT
      S: 221 bye
      """

  Scenario: Implicit TLS needs no STARTTLS, and AUTH LOGIN is used when PLAIN is not offered
    Given the SMTP server speaks "implicit"
    And the SMTP server offers AUTH "LOGIN"
    And the SMTP server is listening
    And the client uses "implicit" security
    And the client logs in as "ana" with the password "secret"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send succeeds
    And the server transcript has the line "C: AUTH LOGIN"
    And the server transcript has the line "C: YW5h"
    And the server transcript has the line "C: c2VjcmV0"
    And the server transcript has the line "S: 235 2.7.0 authenticated"
    And the server transcript has no line starting with "C: STARTTLS"
    And the server transcript has 1 lines starting with "C: EHLO"

  Scenario: A message with text and HTML is multipart/alternative, and a subject with UTF-8 is an encoded word
    Given the SMTP server speaks "plain"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "Ana <ana@example.com>" to "bob@example.com" with the subject "Hola señor", the text "Plain hello" and the html "<p>HTML hello</p>"
    Then the send succeeds
    And the server transcript has the line "C: From: Ana <ana@example.com>"
    And the server transcript has the line "C: Subject: =?UTF-8?B?SG9sYSBzZcOxb3I=?="
    And the server transcript has a line starting with "C: Content-Type: multipart/alternative; boundary="
    And the server transcript has the line "C: Content-Type: text/plain; charset=utf-8"
    And the server transcript has the line "C: Content-Type: text/html; charset=utf-8"
    And the server transcript has the line "C: Plain hello"
    And the server transcript has the line "C: <p>HTML hello</p>"
    And the server transcript has a line starting with "C: --=_"

  Scenario: A line that starts with a dot gets another dot, so that it does not end the message
    Given the SMTP server speaks "plain"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Dots" and the text:
      """
      Before
      .hidden
      .
      After the dot
      """
    Then the send succeeds
    And the server transcript has the line "C: ..hidden"
    And the server transcript has the line "C: .."
    And the server transcript has the line "C: After the dot"

  Scenario: Two messages go over one connection with one EHLO and one QUIT
    Given the SMTP server speaks "plain"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send two messages on one connection
    Then the send succeeds
    And the server transcript has 1 lines starting with "C: EHLO"
    And the server transcript has 2 lines starting with "C: MAIL FROM"
    And the server transcript has the line "C: RCPT TO:<bob@example.com>"
    And the server transcript has the line "C: RCPT TO:<cy@example.com>"
    And the server transcript has 1 lines starting with "C: QUIT"

  Scenario: The date and the message id are made when the message has none
    Given the SMTP server speaks "plain"
    And the SMTP server is listening
    And the client uses "plain" security
    And the client makes the date and the message id itself
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send succeeds
    And the server transcript has a line starting with "C: Date: "
    And the server transcript has a line starting with "C: Message-ID: <"

  Scenario: A server that does not offer STARTTLS gets no message and no password
    Given the SMTP server speaks "plain"
    And the SMTP server offers AUTH "PLAIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "secret"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the error mentions "STARTTLS"
    And the server transcript has no line starting with "C: AUTH"
    And the server transcript has no line starting with "C: MAIL FROM"

  Scenario: A plain connection is only for this machine
    Given the client uses "plain" security
    And the client connects to the host "mail.example.com"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the error mentions "plain connection"

  Scenario: A 5xx for a recipient fails the send with its code, and nothing is delivered
    Given the SMTP server speaks "plain"
    And the SMTP server refuses the recipient "eve@example.com"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "ana@example.com" to "bob@example.com,eve@example.com" with the subject "Hello" and the text:
      """
      Hi.
      """
    Then the send fails with the code 550
    And the error mentions "recipient eve@example.com refused"
    And the server transcript has the line "C: RCPT TO:<bob@example.com>"
    And the server transcript has the line "C: RCPT TO:<eve@example.com>"
    And the server transcript has the line "C: RSET"
    And the server transcript has no line starting with "C: DATA"

  Scenario: A login that the server refuses fails with its code and never shows the password
    Given the SMTP server speaks "starttls"
    And the SMTP server offers AUTH "PLAIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "wrong-password"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails with the code 535
    And the error does not mention "wrong-password"
    And the server transcript has no line starting with "C: MAIL FROM"

  Scenario: A reply that does not come in time is a timeout, without a code
    Given the SMTP server speaks "plain"
    And the SMTP server never answers "RCPT"
    And the SMTP server is listening
    And the client uses "plain" security
    And the client waits 500 milliseconds for each reply
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the error mentions "timed out"
    And the error mentions "RCPT TO"

  Scenario: A reply that is only a code, which RFC 5321 allows, is a reply
    Given the SMTP server speaks "plain"
    And the SMTP server answers "MAIL" with "250"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send succeeds
    And the server transcript has the line "S: 250"

  Scenario Outline: A line that is not a reply fails the send without a code and closes the connection
    Given the SMTP server speaks "plain"
    And the SMTP server answers "RCPT" with "<reply>"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the error mentions "not a reply"
    And the server transcript has no line starting with "C: DATA"
    And the server saw the connection close

    Examples:
      | reply                |
      | OK                   |
      |                      |
      | +25 plus             |
      | 000 zero             |
      | 250-first\|251 second |

  Scenario: A reply with more lines than the client reads fails the send
    Given the SMTP server speaks "plain"
    And the SMTP server answers "RCPT" with "~150"
    And the SMTP server is listening
    And the client uses "plain" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the error mentions "more than"

  Scenario: The timeout is for the whole reply, not for each line of it
    Given the SMTP server speaks "plain"
    And the SMTP server answers "RCPT" with "~40"
    And the SMTP server pauses 100 milliseconds between the lines of a reply
    And the SMTP server is listening
    And the client uses "plain" security
    And the client waits 500 milliseconds for each reply
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the error mentions "timed out"

  Scenario: A 4xx for STARTTLS fails the send with its code and closes the connection
    Given the SMTP server speaks "starttls"
    And the SMTP server answers "STARTTLS" with "454 TLS not available"
    And the SMTP server is listening
    And the client uses "starttls" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails with the code 454
    And the server transcript has no line starting with "C: MAIL FROM"
    And the server saw the connection close

  Scenario: AUTH LOGIN goes over the encrypted connection, after STARTTLS
    Given the SMTP server speaks "starttls"
    And the SMTP server offers AUTH "LOGIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "secret"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send succeeds
    And the server transcript has the line "C: AUTH LOGIN"
    And the server transcript has no line starting with "S: 530"
    And the server transcript has 2 lines starting with "C: EHLO"

  Scenario: A login that is refused after STARTTLS closes the encrypted connection
    Given the SMTP server speaks "starttls"
    And the SMTP server offers AUTH "PLAIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "wrong-password"
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails with the code 535
    And the server saw the connection close

  Scenario: An EHLO that is refused after STARTTLS closes the encrypted connection
    Given the SMTP server speaks "starttls"
    And the SMTP server answers "EHLO#2" with "554 no service"
    And the SMTP server is listening
    And the client uses "starttls" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails with the code 554
    And the server saw the connection close

  Scenario: A certificate that the client does not trust fails the send, and nothing is sent after it
    Given the SMTP server speaks "starttls"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client trusts only the system certificates
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the server transcript has no line starting with "C: MAIL FROM"

  Scenario: A certificate for another host name fails the send
    Given the SMTP server speaks "implicit"
    And the SMTP server uses the certificate "wrong-host"
    And the SMTP server is listening
    And the client uses "implicit" security
    When I send a message from "ana@example.com" to "bob@example.com" with the subject "Hello" and the text:
      """
      Hi Bob.
      """
    Then the send fails without a code
    And the server transcript has no line starting with "C: EHLO"

  Scenario: The public steps open, EHLO, STARTTLS, login and send go on with the encrypted client
    Given the SMTP server speaks "starttls"
    And the SMTP server offers AUTH "PLAIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "secret"
    When I send a message over a connection that I open, upgrade and log in step by step
    Then the send succeeds
    And the server transcript has the line "C: STARTTLS"
    And the server transcript has the line "C: AUTH PLAIN AGFuYQBzZWNyZXQ="
    And the server transcript has the line "C: RCPT TO:<bob@example.com>"
    And the server transcript has the line "S: 221 bye"

  Scenario: The client that connect gives does not keep the password
    Given the SMTP server speaks "starttls"
    And the SMTP server offers AUTH "PLAIN"
    And the SMTP server is listening
    And the client uses "starttls" security
    And the client logs in as "ana" with the password "secret"
    When I connect, find that the client no longer holds the password, and send a message
    Then the send succeeds
