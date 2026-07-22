#ifndef _JSON_WRITER_H_
#define _JSON_WRITER_H_



/*
 * json_writer.h — the only "JSON library" this project needs.
 *
 * Nothing in verbatimd ever parses incoming JSON: the POST body is raw
 * text to speak, and every other input (voice, speed, ndjson toggle)
 * arrives as an HTTP header, not a JSON body. All we ever do is *build*
 * small JSON responses (errors, status, voice lists, NDJSON event lines).
 *
 * That means there's no need to hand-port cJSON to Objective-C at all —
 * Foundation already ships a JSON writer, NSJSONSerialization, which every
 * file that imports Foundation already has for free, and which handles
 * string escaping correctly (including voice names or error text that
 * might contain quotes/backslashes/control characters, which the old
 * cJSON dependency also had to handle). This header wraps it in the one
 * shape the rest of the project needs: build a plain NSDictionary/NSArray
 * literal, serialize it to bytes suitable for http_send_response()/
 * http_write_chunk().
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Serializes a JSON-compatible Foundation object graph — an NSDictionary
 * or NSArray at the top level (NSJSONSerialization's own requirement),
 * containing NSString/NSNumber/NSArray/NSDictionary — into a NUL-terminated,
 * malloc'd UTF-8 buffer. Caller must free() the returned buffer.
 *
 * On success, *out_len is set to the byte length (NOT including the
 * trailing NUL) — pass it straight to http_send_response()/
 * http_write_chunk(). Returns NULL (and logs an error) on failure, which
 * should not happen for well-formed input built from NSDictionary/NSArray
 * literals of strings, numbers, and booleans. */
char *_Nullable json_serialize_alloc(id object, size_t *out_len);

NS_ASSUME_NONNULL_END


#endif  // _JSON_WRITER_H_
