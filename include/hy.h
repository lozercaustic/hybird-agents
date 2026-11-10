/* libhy C ABI v1 — the store format is private; use these. */
int  hy_abi(void);                                   /* returns 1 */
/* Tab-separated lines: H bytes facts msgs pending results | D id text | M from to text |
   R who task text | F s r o.  Returns bytes needed (write min(needed,cap)); -1 on error. */
long hy_snapshot(char *buf, unsigned long cap);
int  hy_answer(unsigned id, const char *text);       /* answer pending decision; 0 ok */
int  hy_send(const char *from, const char *to, const char *text);
int  hy_learn(const char *who, const char *s, const char *r, const char *v);
