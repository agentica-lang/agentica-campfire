# Email

Email is for the password reset. With `CAMPFIRE_SMTP_URL` unset the app says `mail: off` at start,
the reset pages answer `404` and the sign-in page has no link to them. Variables:
[configuration.md](configuration.md).

## SMTP

`CAMPFIRE_SMTP_URL` forms:

- `smtp://user:password@host:587` (or `smtp+starttls://`): STARTTLS, and the app refuses to send
  unless the server offers it.
- `smtps://user:password@host:465`: TLS from the first byte.
- `smtp+plain://host:1025`: no TLS, accepted only for a host on this machine (a mail catcher in
  development).

The user and the password are percent-encoded (`%40` for `@`) and both are left out for a server
without login. The password is never logged or shown in an error.

With the url set, `CAMPFIRE_BASE_URL` is required: the links in emails start with it, since the
`Host` of a request is the visitor's to choose.

## The mailer

A request never sends email. It hands the message to a task (`src/campfire/mail/mailer.agc`), so a
slow or dead mail server never holds up a page.

- The queue holds `CAMPFIRE_MAIL_QUEUE_SIZE` messages.
- A message that cannot be sent is logged with the code and the label of the refusal only
  (`campfire: mail: a message to 1 recipient was not sent: smtp 535: authentication failed`: no
  password, no address, no words of the server) and dropped.
- A stop of the app sends what is queued first. It waits up to 10 seconds, then logs how many it
  dropped.

The SMTP client (`src/campfire/mail/smtp.agc` and `smtp_message.agc`) imports nothing else of the
app.

## Password reset

"Forgot your password?" on the sign-in page asks for an email. The answer is the same page whether
or not an account has it.

For an active account the app emails a link, `BASE_URL/password_reset/edit?token=...`, with a
random 256-bit token of which the table `password_resets` keeps only the SHA-256.

- The link works once and for 30 minutes.
- While a person has a link that works, asking again sends nothing, so a stranger cannot replace
  the link that the person is about to open.
- After a link was used or made, a new one comes only five minutes later, so the form cannot be used
  to flood an inbox. There is no other limit until the per-IP limit exists
  ([agentica-campfire#9](https://github.com/agentica-lang/agentica-campfire/issues/9)).
- A message dropped as it is queued (the queue is full or the mailer has stopped) deletes its link,
  so the person can ask again. A message that fails to send, or that a stop gives up on, leaves its
  link alive until it expires.

Opening the link only shows the form, so a mail scanner that opens it uses nothing up (the page is
`no-store` with `Referrer-Policy: no-referrer`). Posting the form sets the new password under the
rules and the hashing limit of the first run (a post that finds the slots busy gets `503` with the
form again), deletes every session of that person, uses the link
up and signs the browser in.

Requests that come together are decided inside one write transaction (`BEGIN IMMEDIATE`), so they
send one email and two forms for one link change the password once (the second may hash for
nothing, which the limit on hashes bounds). A request that finds the database busy waits for it
in its task, so a burst does not fail with "database is locked", for at most the `busy_timeout` of agentica-db (5 seconds); a longer wait is a
database error, answered `500`.
