## The links that sign a person in on another device (Rails' `Sessions::TransfersController`). Rails signs the user id
## and lets the link work for 4 hours, as many times as it is opened; here a link works once and for `LIFETIME_MS`, and
## only a SHA-256 of its random part is kept, in memory, so a restart ends every link. A person has at most one link: a
## new one replaces the last, so the table holds at most one entry for each person who made a link since the start.
## A link also names the session that made it, and using it opens a session only while that one is still there
## (`Auth.open_transferred_session`): a sign-out, a password reset, a deactivation or a ban, which delete the sessions
## of the person, end the link too. The tables are shared by the request tasks.

## How long a link works: 15 minutes.
LIFETIME_MS = 900_000

## The link of a person: the digest of its secret, the session that made it, when it stops working (a monotonic clock)
## and its serial, which names its claim.
struct Link
  digest: String
  session_id: Int
  expires_ms: Int
  serial: Int
end

## The links (by person) and their claims (by person and serial).
struct Links
  links: ATS[String, Link]
  claims: ATS[String, Int]
end

## What a link that works gives: the person and the session that made the link.
struct Grant
  user_id: Int
  session_id: Int
end

## New, empty tables.
def new() -> Links
  links: ATS[String, Link] = ATS.new()
  claims: ATS[String, Int] = ATS.new()
  Links(links: links, claims: claims)
end

## A new link token for `user_id`, made in the session `session_id` at `now_ms` (a monotonic clock). It replaces the
## person's last link. The token is `USER_ID-SECRET`.
def issue(table: Links, user_id: Int, session_id: Int, now_ms: Int) -> String
  secret = OpenSSL.Random.hex(SECRET_BYTES)
  serial = ATS.add(table.claims, SERIAL, 1)
  person = person_key(user_id)
  old = ATS.get(table.links, person)
  ATS.put(
    table.links,
    person,
    Link(digest: digest(secret), session_id: session_id, expires_ms: now_ms + LIFETIME_MS, serial: serial),
  )

  if old.ok?
    ATS.delete(table.claims, claim_key(user_id, old.unwrap!.serial))
  end

  "#{user_id}-#{secret}"
end

## The person of the link `token` and the session that made it, when the link is alive, not used yet and still the
## person's last one (also when a new link is made during this call); the link is used up by this call. Of two calls
## with the same token at once, at most one gets the grant.
def redeem(table: Links, token: String, now_ms: Int) -> Optional[Grant]
  dash = token.index_of("-")
  return none if dash.none?

  user_id = token.slice(0, dash.unwrap!).to_i
  secret = token.slice(dash.unwrap! + 1, token.length - dash.unwrap! - 1)
  return none if not user_id.ok? or secret.empty?

  found = ATS.get(table.links, person_key(user_id.unwrap!))
  return none if not found.ok?

  link = found.unwrap!
  return none if not OpenSSL.HMAC.secure_compare(link.digest.bytes, digest(secret).bytes) or link.expires_ms <= now_ms

  # The claim is the one atomic step. A link replaced meanwhile gives nothing, and its claim stays: `issue` has already
  # deleted the claims of that serial, so a claim taken back here would let a second call claim it again. Such a claim
  # is left only by this race, at most one for each new link.
  claimed = ATS.add(table.claims, claim_key(user_id.unwrap!, link.serial), 1) == 1
  current = ATS.get(table.links, person_key(user_id.unwrap!))
  return none if not claimed or not current.ok? or current.unwrap!.serial != link.serial

  some(Grant(user_id: user_id.unwrap!, session_id: link.session_id))
end

private

SECRET_BYTES = 32
# The counter of the serials, in the table of the claims (a claim key always has a `|`).
SERIAL = "serial"

def person_key(user_id: Int) -> String = user_id.to_s

def claim_key(user_id: Int, serial: Int) -> String = "#{user_id}|#{serial}"

def digest(secret: String) -> String = OpenSSL.Digest.sha256_hexdigest(secret.bytes)
