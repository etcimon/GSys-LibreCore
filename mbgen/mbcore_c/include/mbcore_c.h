#ifndef MBCORE_C_H
#define MBCORE_C_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mb_session mb_session;

/* UTF-8 JSON in and out. Caller frees returned strings with mb_string_free.
   panic=abort. No callbacks. No threads. UBT does not compile this crate. */

mb_session *mb_session_open(const char *design_json);
void mb_session_close(mb_session *session);

/* Gesture JSON -> PreviewResult JSON. Pack only. */
char *mb_apply(mb_session *session, const char *gesture_json);

/* dirty_only != 0: nets touching the last applied part, plus rails.
   Always rails + 2-pin A* on pad XY. */
char *mb_route(mb_session *session, int dirty_only);

char *mb_scene(mb_session *session);
char *mb_anchors(mb_session *session);
char *mb_library_json(void);
void mb_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
