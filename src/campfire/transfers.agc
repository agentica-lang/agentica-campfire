## The links that sign a person in on another device (Rails' `Sessions::TransfersController`). Rails signs the user id
## and lets the link work for 4 hours, as many times as it is opened; here a link works once and for `LIFETIME_MS`, and
## only a SHA-256 of its random token is kept, in memory, so a restart ends every link. The table is shared by the
## request tasks. Using a link does not check the person: `Auth.open_session` refuses one who is not active.

## How long a link works: 15 minutes.
LIFETIME_MS = 900_000
## The most links alive at once; past it no link is made until some expire.
MAX_LINKS = 10_000

## A new table of links.
def new() -> ATS[String, Int]
  links: ATS[String, Int] = ATS.new()
  links
end

## A new link token for `user_id` at `now_ms` (a monotonic clock), or `none` when `MAX_LINKS` are alive.
def issue(links: ATS[String, Int], user_id: Int, now_ms: Int) -> Optional[String]
  sweep(links, now_ms)
  return none if ATS.size(links) >= MAX_LINKS * KEYS_PER_LINK

  token = OpenSSL.Random.hex(TOKEN_BYTES)
  key = digest(token)
  ATS.put(links, "#{key}#{EXPIRES}", now_ms + LIFETIME_MS)
  ATS.put(links, key, user_id)
  some(token)
end

## The person of the link `token` when it is alive and not used yet; the link is used up by this call. Of two calls with
## the same token at once, one gets the person.
def redeem(links: ATS[String, Int], token: String, now_ms: Int) -> Optional[Int]
  key = digest(token)
  user_id = ATS.get(links, key)
  expires = ATS.get(links, "#{key}#{EXPIRES}")
  return none if not user_id.ok? or not expires.ok? or expires.unwrap! <= now_ms

  # The claim is the one atomic step: it stays until the sweep, so a late second call cannot claim again.
  return none if ATS.add(links, "#{key}#{CLAIMED}", 1) != 1

  ATS.delete(links, key)
  some(user_id.unwrap!)
end

private

TOKEN_BYTES = 32
# A link is `DIGEST` (the user), `DIGEST|e` (when it expires) and, once used, `DIGEST|c`.
EXPIRES = "|e"
CLAIMED = "|c"
KEYS_PER_LINK = 3

def digest(token: String) -> String = OpenSSL.Digest.sha256_hexdigest(token.bytes)

# Removes the links that have expired, used or not.
def sweep(links: ATS[String, Int], now_ms: Int) -> Void
  for name in ATS.keys(links)
    if name.end_with?(EXPIRES) and ATS.get(links, name).unwrap_or(0) <= now_ms
      key = name.slice(0, name.length - EXPIRES.length)
      ATS.delete(links, key)
      ATS.delete(links, "#{key}#{CLAIMED}")
      ATS.delete(links, name)
    end
  end
end
