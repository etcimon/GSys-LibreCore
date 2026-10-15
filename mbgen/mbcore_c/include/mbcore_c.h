#ifndef MBCORE_C_H
#define MBCORE_C_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mb_session mb_session;

/* UTF-8 JSON in and out. Caller frees returned strings with mb_string_free.
   panic=abort. No callbacks. No threads. UBT does not compile this crate. */

/* ABI version. A host built against a different major must not call in. */
#define MBCORE_C_ABI_VERSION 2
unsigned int mb_abi_version(void);

mb_session *mb_session_open(const char *design_json);
void mb_session_close(mb_session *session);

/* Monotonic per-session revision. Bumps once per APPLIED gesture. Results
   carry the revision they were computed against; a host drops stale ones. */
unsigned long long mb_session_revision(const mb_session *session);

/* Gesture JSON -> PreviewResult JSON (+ "revision"). Pack only. */
char *mb_apply(mb_session *session, const char *gesture_json);

/* dirty_only != 0: nets touching the last applied part, plus rails.
   Always rails + 2-pin A* on pad XY. Result carries "revision" and
   "dirty_only" so the host does not treat a filtered result as a full set. */
char *mb_route(mb_session *session, int dirty_only);

char *mb_scene(mb_session *session);
char *mb_anchors(mb_session *session);
char *mb_library_json(void);
void mb_string_free(char *s);

/* ---- Navigation laws (actor-local preview centimetres, Z up) ----------
   One implementation for the editor viewport and the standalone pawn. Every
   vector is a double[3] {x, y, z}; a desk is double[5] {cx, cy, z, hx, hy}
   (finite rest plane, see mb_nav_desk). Returns 0 on success, nonzero on a
   null pointer. Outputs may alias inputs. */
int mb_nav_desk(double board_w_cm, double board_d_cm, double z_cm, double *out_desk5);
/* Empty-click orbit/dolly pivot: plane hit inside the desk, else a point on
   the cursor ray at the last focus depth. Never a clamped rim corner. */
int mb_nav_pick_pivot(const double *desk5, const double *cam3, const double *dir3,
                      const double *last_pivot3, double *out_pivot3);
/* Camera on a sphere around pivot, still looking at it, roll 0. */
int mb_nav_orbit(const double *pivot3, const double *cam3, double yaw_deg, double pitch_deg,
                 double *out_cam3, double *out_forward3);
/* Camera fixed; yaw about world Z, pitch about camera right; roll 0. */
int mb_nav_look(const double *forward3, double yaw_deg, double pitch_deg, double *out_forward3);
/* Dolly along the pick ray by clamped wheel notches at the given sensitivity. */
int mb_nav_zoom_toward(const double *cam3, const double *hit3, double notches, double sens,
                       double *out_cam3);
double mb_nav_zoom_distance(double dist, double notches, double sens);

#ifdef __cplusplus
}
#endif

#endif
