#ifndef WETYPE_INPUT_SCHEME_H
#define WETYPE_INPUT_SCHEME_H

#include <string.h>

/* WeType 3.5.4 SessionConfig.DoublePinSolution: DISABLED=0, XIAOHE=3.
 * Keep full pinyin as the default for existing Linux installations. */
static int wetype_double_pin_solution(const char *scheme) {
    if (!scheme || !*scheme || !strcmp(scheme, "full")) return 0;
    if (!strcmp(scheme, "flypy")) return 3;
    return -1;
}

#endif
