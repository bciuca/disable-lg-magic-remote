#ifndef TEST_GUM_H
#define TEST_GUM_H
typedef struct GumInterceptor { int dummy; } GumInterceptor;
typedef enum { GUM_REPLACE_OK = 0, GUM_REPLACE_WRONG_SIGNATURE = -1 } GumReplaceReturn;
void gum_init_embedded(void);
GumInterceptor *gum_interceptor_obtain(void);
void gum_interceptor_begin_transaction(GumInterceptor *);
void gum_interceptor_end_transaction(GumInterceptor *);
GumReplaceReturn gum_interceptor_replace(GumInterceptor *, void *, void *, void *, void **);
void gum_interceptor_revert(GumInterceptor *, void *);
#endif
