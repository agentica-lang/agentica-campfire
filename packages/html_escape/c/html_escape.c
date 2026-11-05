/*
 * HTML escaping in one pass, for html_escape.agc: `&`, `<`, `>`, `"` and `'` become `&amp;`, `&lt;`, `&gt;`,
 * `&quot;` and `&#39;`, the output of `HTML.escape` of std/html. Every other byte is copied, so UTF-8 passes
 * through unchanged (the five characters are ASCII and never part of a multibyte sequence).
 *
 * The result is a NUL-terminated string in a buffer that this library owns, one per thread: the VM copies a
 * `C.String` result before the call returns, and a `def` call runs on one scheduler thread from start to end, so
 * the buffer is read before any other call on that thread can reuse it. Nothing is handed to the caller to free.
 *
 * Running out of memory ends the run with exit code 70, as the VM itself does, so the result is never NULL: a NULL
 * `C.String` would read as "" and a value would silently vanish from a page.
 */
#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* A buffer that grew past this is given back at the next call that needs less, so a thread keeps at most this
 * much between calls once its long texts are done. */
#define KEEP_BYTES 65536

struct scratch {
    char *data;
    size_t capacity;
};

static _Thread_local struct scratch scratch;
static _Thread_local int scratch_registered;
static pthread_key_t scratch_key;
static pthread_once_t scratch_once = PTHREAD_ONCE_INIT;
static int scratch_key_ok;

/* The key only exists for its destructor, which frees the buffer of a thread that ends. */
static void scratch_free(void *value) {
    struct scratch *s = value;
    free(s->data);
    s->data = NULL;
    s->capacity = 0;
}

static void scratch_key_make(void) {
    scratch_key_ok = pthread_key_create(&scratch_key, scratch_free) == 0;
}

static void out_of_memory(void) {
    static const char line[] = "html_escape: out of memory\n";
    ssize_t ignored = write(2, line, sizeof line - 1);
    (void)ignored;
    _Exit(70);
}

/* A buffer of at least `need` bytes. */
static char *scratch_reserve(size_t need) {
    if (!scratch_registered) {
        pthread_once(&scratch_once, scratch_key_make);
        /* Without the key the buffer still works; it is only not freed when the thread ends. */
        if (scratch_key_ok) {
            pthread_setspecific(scratch_key, &scratch);
        }
        scratch_registered = 1;
    }

    if (scratch.capacity >= need && (scratch.capacity <= KEEP_BYTES || need > KEEP_BYTES)) {
        return scratch.data;
    }

    size_t capacity = need > KEEP_BYTES ? need : KEEP_BYTES;
    char *data = malloc(capacity);
    if (data == NULL) {
        out_of_memory();
    }

    free(scratch.data);
    scratch.data = data;
    scratch.capacity = capacity;
    return data;
}

/* The escaped copy of the NUL-terminated `text`, valid until the next call on this thread. */
const char *campfire_html_escape(const char *text) {
    size_t length = 0;
    size_t extra = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p != '\0'; p++) {
        switch (*p) {
        case '&':
            extra += 4;
            break;
        case '<':
        case '>':
            extra += 3;
            break;
        case '"':
        case '\'':
            extra += 5;
            break;
        default:
            break;
        }
        length++;
    }

    /* At most 5 extra bytes per input byte, so the sum overflows only for a text near SIZE_MAX / 6, which no
     * allocation could hold anyway. */
    if (length > (SIZE_MAX - 1) / 6) {
        out_of_memory();
    }

    char *out = scratch_reserve(length + extra + 1);

    if (extra == 0) {
        memcpy(out, text, length + 1);
        return out;
    }

    char *w = out;
    for (const char *p = text; *p != '\0'; p++) {
        switch (*p) {
        case '&':
            memcpy(w, "&amp;", 5);
            w += 5;
            break;
        case '<':
            memcpy(w, "&lt;", 4);
            w += 4;
            break;
        case '>':
            memcpy(w, "&gt;", 4);
            w += 4;
            break;
        case '"':
            memcpy(w, "&quot;", 6);
            w += 6;
            break;
        case '\'':
            memcpy(w, "&#39;", 5);
            w += 5;
            break;
        default:
            *w++ = *p;
            break;
        }
    }

    *w = '\0';
    return out;
}
