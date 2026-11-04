## The paths of the pages, in one place so that the router, the filter, the redirects and the forms of the views name
## the same ones.

export HOME = "/"
export FIRST_RUN = "/first_run"
export SIGN_IN = "/session/new"
export SESSION = "/session"
export SIGN_OUT = "/sign_out"
export HEALTH = "/health"

## The password reset: the form for the email, the post that asks for the link, the page of the link (with `?token=`)
## and the post that sets the new password.
export PASSWORD_RESET_NEW = "/password_reset/new"
export PASSWORD_RESET = "/password_reset"
export PASSWORD_RESET_EDIT = "/password_reset/edit"
export PASSWORD_RESET_UPDATE = "/password_reset/confirm"
