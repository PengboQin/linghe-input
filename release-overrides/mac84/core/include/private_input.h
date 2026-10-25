#ifndef PRIVATE_INPUT_H
#define PRIVATE_INPUT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef uintptr_t PI_Session;
/* Process-global engine. All paths are app-owned. No network or input logging. */
int pi_initialize(const char *shared_dir, const char *user_dir, int deploy);
/* Select a known learning format at an engine boundary; no I/O or migration.
   Returns 1 on success, 0 for an unknown identity, -2 when changing an active
   runtime. Re-selecting the same profile is safe with existing sessions. */
int pi_set_learning_capacity_profile(const char *profile_id, uint32_t version);
void pi_finalize(void);
PI_Session pi_create_session(void);
void pi_destroy_session(PI_Session session);
size_t pi_active_session_count(void);
int pi_process_key(PI_Session session, int keycode, int modifiers);
int pi_select_candidate(PI_Session session, size_t index);
int pi_delete_candidate(PI_Session session, size_t index);
/* A bounded stream of candidates with absolute engine indices; no UI paging. */
size_t pi_load_candidate_batch(PI_Session session, size_t offset, size_t limit);
/* Same candidate stream, with a resumable budget across pin/path preparation and
   ordinary admission. Counts successful native iterator rows, not milliseconds;
   one native row evaluation can itself be expensive. Zero budget only reads an
   already prepared cache. A short/empty batch with pending=1 is NOT EOF: repeat
   the same offset/limit in a later input-thread turn. Pin/path preparation is
   completed before publishing any rows, so later work never prepends offsets.
   Getters describe the last load call and reset on composition refresh/clear. */
size_t pi_load_candidate_batch_bounded(PI_Session session, size_t offset, size_t limit, size_t maximum_scanned_rows);
int pi_candidate_batch_pending(PI_Session session);
size_t pi_candidate_batch_scanned(PI_Session session);
const char *pi_batch_candidate_text(PI_Session session, size_t index);
const char *pi_batch_candidate_comment(PI_Session session, size_t index);
size_t pi_batch_candidate_index(PI_Session session, size_t index);
int pi_select_candidate_absolute(PI_Session session, size_t index);
void pi_clear(PI_Session session);
int pi_set_private(PI_Session session, int enabled);
int pi_set_nine_key(PI_Session session, int enabled);
/* Nine-key disambiguation: complete syllables and legal unfinished initials.
   An initial narrows this syllable without inserting a boundary; subsequent
   digits can finish it. Complete choices keep their explicit boundary. Neither
   commits host text; indices belong to the latest count call and undo restores
   the original ambiguous spelling, including any subsequently typed tail. */
size_t pi_nine_syllable_count(PI_Session session);
const char *pi_nine_syllable_text(PI_Session session, size_t index);
int pi_nine_select_syllable(PI_Session session, size_t index);
int pi_nine_undo_syllable(PI_Session session);
int pi_nine_can_undo_syllable(PI_Session session);
/* Borrowed strings. Copy before the next operation on the session. */
const char *pi_preedit(PI_Session session);
/* Display nine-key phonetics using the visible candidate; never rewrites raw. */
const char *pi_nine_display_preedit(PI_Session session, const char *reading);
const char *pi_nine_readable_preedit(PI_Session session, const char *reading);
const char *pi_raw_input(PI_Session session);
int pi_cursor_at_end(PI_Session session);
// UTF-8 byte offset in the displayed composition, not the raw spelling.
size_t pi_preedit_cursor_utf8(PI_Session session);
int pi_move_pinyin_cursor(PI_Session session, int direction);
/* Unselected trailing numeric span; SIZE_MAX when no editable span exists. */
size_t pi_prediction_input_start(PI_Session session);
size_t pi_unselected_input_start(PI_Session session);
const char *pi_selected_prefix(PI_Session session);
/* Soft nine-key continuity: publish only a verified complete visible reading.
   Exact raw/prefix identity is required. No text is committed or input locked.
   preferred_reading is a borrowed remaining path after a partial selection;
   empty means unknown. Other readings remain selectable. */
int pi_nine_remember_candidate_path(PI_Session session,const char *expected_raw,const char *expected_selected_prefix,const char *full_reading);
/* A displayed correction row may supply an explicit canonical pending code.
   Only bounded edit mappings with uniquely provable later syllable boundaries
   are retained. This is still an optional ranking hint, never an input edit. */
int pi_nine_remember_mapped_candidate_path(PI_Session session,const char *expected_raw,const char *expected_selected_prefix,const char *full_reading,const char *canonical_pending_code);
const char *pi_nine_preferred_reading(PI_Session session);
/* Shared publication tier: 0 full current path, 1 compatible prefix word,
   2 unrelated/unknown/untyped extension. Stable order within each tier. */
int pi_nine_candidate_path_priority(PI_Session session,const char *candidate_reading);
/* Bind actual published Han text (one character per full syllable), never a
   guessed string. canonical_pending_code may be NULL for exact input. */
int pi_nine_remember_visible_candidate_path(PI_Session session,const char *expected_raw,const char *expected_selected_prefix,const char *full_text,const char *full_reading,const char *canonical_pending_code);
const char *pi_nine_preferred_text(PI_Session session);
/* Explicit strict prefix choice: bound canonical native selection, no commit. */
int pi_select_nine_preferred_prefix(PI_Session session,const char *expected_raw,const char *expected_selected_prefix,const char *text,const char *reading);
/* Explicit click only; exact current raw/prefix/text/reading binding required.
   Returns a direct result once; pi_take_commit does not replay this result. */
const char *pi_commit_nine_preferred_candidate(PI_Session session,const char *expected_raw,const char *expected_selected_prefix,const char *text,const char *reading);
/* Replace only that span, retaining locked spellings and selected Chinese. */
int pi_replace_pending_input(PI_Session session,const char *expected,const char *replacement);
/* Private query session only; never processes a sequence of committing keys. */
int pi_set_prediction_input(PI_Session session,const char *input);
/* Separate non-learning abbreviation query; never switch a live composition. */
int pi_set_nine_initials_probe_input(PI_Session session,const char *input);
/* Private full-pinyin query/commit staging, never changes a live session. */
int pi_set_pinyin_probe_input(PI_Session session,const char *input);
int pi_stage_pinyin_input(PI_Session session,const char *input);
/* Explicit candidate commit staging: fresh nine-key session only. */
int pi_stage_nine_input(PI_Session session,const char *canonical_pinyin);
int pi_page_number(PI_Session session);
int pi_has_next_page(PI_Session session);
int pi_set_ascii_mode(PI_Session session, int enabled);
/* Automatic suggestion admission only; never use to rewrite literal/user data. */
int pi_candidate_text_allowed(const char *text);
/* Pure automatic reading eligibility; never apply to literal/storage or explicit aliases. */
int pi_candidate_reading_allowed(const char *text,const char *reading);
size_t pi_candidate_count(PI_Session session);
const char *pi_candidate_text(PI_Session session, size_t index);
const char *pi_take_commit(PI_Session session);
/* Bounded spelling repairs for the unselected suffix of a Latin composition.
   Proposals are validated against this same dictionary; never commits. */
/* Pure immutable public-data preparation; never calls Rime or reads user data. */
int pi_prepare_repair_resources(const char *signed_resource_directory);
size_t pi_load_repair_candidates(PI_Session session, size_t limit);
const char *pi_repair_candidate_text(PI_Session session, size_t index);
const char *pi_repair_candidate_reading(PI_Session session, size_t index);
const char *pi_repair_candidate_spelling(PI_Session session, size_t index);
size_t pi_repair_candidate_edits(PI_Session session, size_t index);
/* Commit one loaded repair row, replacing only the unselected suffix. */
const char *pi_commit_repair_candidate(PI_Session session, size_t index);
int pi_export_learning(const char *file);
int pi_import_learning(const char *file);
/* Own adapter controls. Reset is allowed only with every session closed. */
int pi_reset_word_frequency(const char *reading, const char *text, uint64_t count);
int pi_set_word_pinned(const char *reading, const char *text, int pinned);
const char *pi_engine_version(void);
/* Optional offline collocation model. NAN score means unavailable; no text logging. */
int pi_language_initialize(const char *signed_resource_directory);
void pi_language_release(void);
double pi_language_score(const char *preceding_own_text, const char *candidate_text);
uint64_t pi_process_memory_footprint(void);
uint64_t pi_process_peak_memory_footprint(void);
uint64_t pi_available_memory(void);
#ifdef __cplusplus
}
#endif
#endif
