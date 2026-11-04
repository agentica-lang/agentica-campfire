Feature: Sending email from the app
  The app hands a message to a mailer task and answers at once, so a slow mail server never holds up a page. A message
  that cannot be sent is logged without the password of the mail server, and the app goes on. Without
  CAMPFIRE_SMTP_URL the app runs with email off and says so.

  Scenario: Without a mail server the app says that email is off, and the reset pages are not there
    Given a fresh database
    When the app starts
    Then the app said "mail: off (CAMPFIRE_SMTP_URL is not set, so no email is sent)"
    When I get "/password_reset/new"
    Then the status is 404
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 404
    When I get "/session/new"
    Then the body does not contain "password_reset"

  Scenario: With a mail server the app says where it sends
    Given a fresh database
    And the mail server is listening
    And the app sends its email through the mail server
    When the app starts
    Then the app said a line starting with "mail: sending through 127.0.0.1:"

  Scenario: A slow mail server does not hold up the answer, and the app goes on serving
    Given a fresh database
    And the mail server never answers "EHLO"
    And the mail server is listening
    And the app sends its email through the mail server
    And the app starts
    And the first admin exists
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    And the answer came within 1500 milliseconds
    When I get "/health"
    Then the status is 200

  Scenario: A message that the mail server refuses is logged without the password, and the answer is the usual one
    Given a fresh database
    And the mail server offers AUTH "PLAIN"
    And the mail server is listening
    And the app sends its email through the mail server
    And the app logs in to the mail server as "ana" with the password "not-the-password-xyz"
    And the app starts
    And the first admin exists
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    And the body contains "If an account has that email"
    When I close stdin
    Then the program exits with code 0 within 10000 milliseconds
    And stderr is:
      """
      campfire: mail: a message to 1 recipient was not sent: smtp 535: authentication failed

      """

  Scenario: The log of a refused recipient has neither the address nor the words of the server
    Given a fresh database
    And the mail server refuses the recipient "ana@example.com"
    And the mail server is listening
    And the app sends its email through the mail server
    And the app starts
    And the first admin exists
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    When I close stdin
    Then the program exits with code 0 within 10000 milliseconds
    And stderr is:
      """
      campfire: mail: a message to 1 recipient was not sent: smtp 550: a recipient was refused

      """

  Scenario: A message that the mailer drops leaves no link behind, so the person can ask again
    Given a fresh database
    And the mail server never answers "EHLO"
    And the mail server is listening
    And the app sends its email through the mail server
    And the app queues at most 1 messages for the mail server
    And the app starts
    And the first admin exists
    And I run the sql "insert into users (name, email, password_digest) values ('Bea', 'bea@example.com', 'x'), ('Cy', 'cy@example.com', 'x')"
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And I post to "/password_reset" the form:
      | email | bea@example.com |
    And I post to "/password_reset" the form:
      | email | cy@example.com |
    Then the status is 200
    And the query "select count(*) from password_resets" gives at most 2

  Scenario: A stop that gives up on a mail server says what it dropped
    Given a fresh database
    And the mail server never answers "EHLO"
    And the mail server is listening
    And the app sends its email through the mail server
    And the app starts
    And the first admin exists
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    And the mail server heard "EHLO"
    And I close stdin
    Then the program exits with code 0 within 20000 milliseconds
    And stderr is:
      """
      campfire: mail: the mailer was stopped while it was sending, so that message and 0 waiting ones were dropped

      """

  Scenario: A mail server that is not there does not stop the app
    Given a fresh database
    And the app sends its email to a port where no mail server listens
    And the app starts
    And the first admin exists
    When I post to "/password_reset" the form:
      | email | ana@example.com |
    Then the status is 200
    When I get "/health"
    Then the status is 200

  Scenario: A start with a mail server and no public address stops
    Given the environment variable "CAMPFIRE_HOST" is "127.0.0.1"
    And the environment variable "CAMPFIRE_PORT" is "0"
    And the environment variable "CAMPFIRE_DATA_DIR" is "unused"
    And the environment variable "CAMPFIRE_SESSION_SECRET" is "0123456789abcdef0123456789abcdef"
    And the environment variable "CAMPFIRE_SMTP_URL" is "smtp://ana:hunter2@mail.example.com"
    And the Agentica program "fixtures/server.agc"
    Then the program exits with code 1 within 5000 milliseconds
    And stderr is:
      """
      campfire: CAMPFIRE_BASE_URL is required with CAMPFIRE_SMTP_URL: the links in emails start with it

      """

  Scenario: A public address on plain HTTP for a host that is not this machine is warned about at start
    Given a fresh database
    And the mail server is listening
    And the app sends its email through the mail server
    And the app is given the public address "http://chat.example.com"
    And the app starts
    When I close stdin
    Then the program exits with code 0 within 10000 milliseconds
    And stderr is:
      """
      campfire: warning: CAMPFIRE_BASE_URL is http:// for a host that is not this machine, so the links in emails and what follows them go over plain HTTP

      """

  Scenario: A public address on plain HTTP for this machine needs no warning
    Given a fresh database
    And the mail server is listening
    And the app sends its email through the mail server
    And the app is given the public address "http://localhost:3000"
    And the app starts
    When I close stdin
    Then the program exits with code 0 within 10000 milliseconds
    And stderr is:
      """
      """

  Scenario: Secure cookies with a public address on plain HTTP stop the start
    Given the environment variable "CAMPFIRE_HOST" is "127.0.0.1"
    And the environment variable "CAMPFIRE_PORT" is "0"
    And the environment variable "CAMPFIRE_DATA_DIR" is "unused"
    And the environment variable "CAMPFIRE_SESSION_SECRET" is "0123456789abcdef0123456789abcdef"
    And the environment variable "CAMPFIRE_SECURE_COOKIES" is "true"
    And the environment variable "CAMPFIRE_BASE_URL" is "http://chat.example.com"
    And the Agentica program "fixtures/server.agc"
    Then the program exits with code 1 within 5000 milliseconds
    And stderr is:
      """
      campfire: CAMPFIRE_BASE_URL must start with https:// when CAMPFIRE_SECURE_COOKIES is true

      """
