## The cache of rendered messages, as Rails Campfire caches its message partial (`cache [
## message_fragment_cache_key(message), ... ]` in `messages/_message.html.erb`): the markup of each message of a room
## page and of the page of older messages is kept under a key that holds everything the markup is made of, so a hit
## skips cleaning the body and rendering it.
##
## The markup of a message is the same for every viewer (who is signed in and which messages are "mine" are not in it),
## so one entry serves everybody. The key is the message id, its `updated_at` and a SHA-256 of the author's name, the
## time and the body as the database holds them. Rails digests the same things (the attributes of the message, its
## creator and its room, and the body) because a rename, a body or a boost can change the markup without touching the
## `updated_at` of the message, and another program may write to the database. So an edit, a rename of the author or a
## body that another program changed gives a new key, and the old entry is never read again (the cache drops it when it
## needs room). A delete needs nothing: the page does not list the message. The markup has no avatar, boost or room name
## today, so none is in the key; whoever adds one to `Views.message` adds it to `key`. The cache is in memory, so a new
## build of the app starts with it empty and the key needs no version.

import Cache from "std/cache"
import Rooms from "../campfire/rooms"
import Views from "views"

# What a megabyte of `CAMPFIRE_CACHE_MB` is.
BYTES_PER_MB = 1024 * 1024

## The cache for `megabytes` of messages, or `none` for 0, which turns it off: every message is rendered each time.
export def start(megabytes: Int) -> Optional[Cache.Store]
  if megabytes <= 0
    return none
  end

  return some(Cache.memory(megabytes * BYTES_PER_MB))
end

## The messages one after the other, as `Views.messages_list` writes them, each from the cache when it is there.
export def list(cache: Optional[Cache.Store], messages: List[Rooms.Stored]) -> String
  return messages.map do |one| html(cache, one) end.join("\n")
end

# The markup of one message, with its body cleaned. Two requests that miss together both render it, which is the same
# text, so one of them wins and nothing is wrong.
def html(cache: Optional[Cache.Store], stored: Rooms.Stored) -> String
  case cache
    none -> return render(stored)
    some(store) -> return Cache.fetch(store, key(stored)) do render(stored) end
  end
end

def render(stored: Rooms.Stored) -> String
  return Views.message(Rooms.clean(stored))
end

# The author is counted and the body goes last, so that no two messages make the same text by moving bytes from one
# part to the next.
def key(stored: Rooms.Stored) -> String
  text = "#{stored.created_at}\n#{stored.author.bytes.size}:#{stored.author}#{stored.body}"
  return "message:#{stored.id}:#{stored.updated_at}:#{Digest.sha256_hexdigest(text.bytes)}"
end
