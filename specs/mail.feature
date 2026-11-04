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
      campfire: mail: a message to 1 recipient was not sent: smtp 535: authentication failed: 5.7.8 credentials rejected

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
