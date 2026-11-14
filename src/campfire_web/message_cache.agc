## The cache of rendered messages, as Rails Campfire caches its message partial (`cache [
## message_fragment_cache_key(message), ... ]` in `messages/_message.html.erb`): the markup of each message of a room
## page and of the page of older messages is kept under a key that holds everything the markup is made of, so a hit
## skips cleaning the body and rendering it.
##
## The markup of a message is the same for every viewer but one thing: the link to the edit page of the person who may
## change it (`Views.message`), so there are two entries at most, with the link and without. The key is the message id,
## whether it has the link, its `updated_at` and a SHA-256 of the room, the author's name, the time, the boosts and the
## body and the file as the database holds them. Rails digests the same things (the attributes of the message, its
## creator and its room, and the body) because a rename, a body or a boost can change the markup without touching the
## `updated_at` of the message, and another program may write to the database. So an edit, a rename of the author or a
## body that another program changed gives a new key, and the old entry is never read again (the cache drops it when it
## needs room). A delete needs nothing: the page does not list the message. The markup has no avatar or room name
## today, so none is in the key; whoever adds one to `Views.message` adds it to `key`. The cache is in memory, so a new
## build of the app starts with it empty and the key needs no version. When the working set outgrows the cache,
## the request whose write starts a rotation waits while the oldest generation is dropped (about 5 µs an entry).

import Cache from "std/cache"
import Attachments from "../campfire/attachments"
import Boosts from "../campfire/boosts"
import Rooms from "../campfire/rooms"
import Views from "views"

## The cache for `megabytes` of messages, or `none` for 0, which turns it off: every message is rendered each time.
def start(megabytes: Int) -> Optional[Cache.Store]
  return none if megabytes <= 0

  some(Cache.memory(megabytes * BYTES_PER_MB))
end

## The messages one after the other, as `Views.messages_list` writes them for the person `user_id` with the account
## `role`, each from the cache when it is there.
def list(cache: Optional[Cache.Store], messages: List[Rooms.Stored], user_id: Int, role: String) -> String
  parts = messages.map do |one| html(cache, one, Rooms.changeable?(one.creator_id, user_id, role)) end
  parts.join("\n")
end

private

# What a megabyte of `CAMPFIRE_CACHE_MB` is.
BYTES_PER_MB = 1024 * 1024

# The markup of one message, with its body cleaned. Two requests that miss together both render it, which is the same
# text, so one of them wins and nothing is wrong.
def html(cache: Optional[Cache.Store], stored: Rooms.Stored, controls: Bool) -> String
  case cache
    none -> render(stored, controls)
    some(store) -> Cache.fetch(store, key(stored, controls)) do render(stored, controls) end
  end
end

def render(stored: Rooms.Stored, controls: Bool) -> String = Views.message(Rooms.clean(stored), controls)

# The creator is in the key too, since the markup names it (`data-creator-id`): a message that went to another person
# with the same name must not keep the old one. So are the boosts, each with its booster and its text: a boost that is
# added or taken away by a program that does not touch `updated_at` must show too. The boosts, the author and the body
# are counted or come last, so that no two messages make the same text by moving bytes from one part to the next.
def key(stored: Rooms.Stored, controls: Bool) -> String
  text = (
    "#{stored.room_id}\n#{stored.creator_id}\n#{stored.created_at}\n#{boosts_text(stored.boosts)}\n" +
    "#{attachment_text(stored.attachment)}\n#{stored.author.bytes.size}:#{stored.author}#{stored.body}"
  )

  "message:#{stored.id}:#{controls}:#{stored.updated_at}:#{OpenSSL.Digest.sha256_hexdigest(text.bytes)}"
end

# The file as text that tells it apart: none, or its size, the size of its name in bytes and its name.
def attachment_text(attachment: Optional[Attachments.Attachment]) -> String
  case attachment
    none -> "-"
    some(file) -> "#{file.byte_size}:#{file.filename.bytes.size}:#{file.filename}"
  end
end

# The boosts as text that tells them apart: how many, and for each its id, its booster and its words, with the size of
# the two names in bytes.
def boosts_text(boosts: List[Boosts.Boost]) -> String
  parts = boosts.map do |one|
    "\n#{one.id}:#{one.booster_id}:#{one.booster.bytes.size}:#{one.booster}#{one.content.bytes.size}:#{one.content}"
  end

  "#{boosts.size}" + parts.join("")
end
