#define SQLITE_CORE 1
#include <stdlib.h>
#include "sqlite3.h"
#include "sqlite-vec.h"

int pinky_vec_init(sqlite3 *db) { return sqlite3_vec_init(db, NULL, NULL); }

int pinky_bind_f32(sqlite3_stmt *stmt, int idx, const double *v, size_t n) {
  float *buf = malloc(n * sizeof(float));
  if (!buf) return SQLITE_NOMEM;
  for (size_t i = 0; i < n; i++) buf[i] = (float)v[i];
  int rc = sqlite3_bind_blob(stmt, idx, buf, (int)(n * sizeof(float)), SQLITE_TRANSIENT);
  free(buf);
  return rc;
}
