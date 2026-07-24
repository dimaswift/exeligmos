/**
 * saros_data.h
 *
 * Compact, flash-resident (`static const`, no heap/RAM copy) snapshot of the
 * solar Saros eclipse data this clock needs. Originally ported from the
 * reference watchface implementation
 * (/Users/dimas/projects/zepp-faces/exeligmos/watchface/index.js), which
 * kept 3 eclipse timestamps per series (1 past + 2 future); extended here
 * to 5 per series (generally 1 past + 4 future) for a longer runway before
 * this device would need updated data.
 *
 * Extracted directly from the full canonical astronomical dataset
 * (@fractonica/temporal-core's solar-temporal-data.json --
 * web/app/features/temporal/generated/solar-temporal-data.json, which spans
 * ~70 eclipses per series back to antiquity and forward for centuries):
 * for each of the 40 currently-active series (Saros 117-156), the window
 * is the 5 consecutive eclipses bracketing 2026-07-17 with 1 eclipse before
 * "now" and 4 after -- except Saros 117, whose dataset only extends to
 * 2054 for that series (a real property of that series in the source data,
 * not a generation bug), so its window is shifted 2 eclipses earlier
 * (2 before "now", 2 after) to still get a full 5-eclipse span. Every
 * window was verified (before extraction) to actually bracket 2026-07-17,
 * i.e. window[0] <= 2026-07-17 < window[4] for all 40 series.
 *
 * Row i (5 consecutive values) is Saros SAROS_FIRST + i. Values are Unix
 * seconds (UTC). Valid usage window per series is [row[0], row[4]) --
 * roughly 90-160 years depending on the series (4 consecutive ~18-year
 * Saros periods for most series); re-extract from the canonical dataset if
 * this device is still running an update near either edge.
 */
#pragma once

#include <stdint.h>

#define SAROS_FIRST 117
#define SAROS_SERIES_COUNT 40
#define SAROS_ECLIPSES_PER_SERIES 5

static const uint32_t SAROS_ECLIPSE_SECONDS[SAROS_SERIES_COUNT * SAROS_ECLIPSES_PER_SERIES] = {
    393509073, 962480014, 1531450936, 2100421926, 2669393042, /* 117 */
    1306963038, 1875931573, 2444899951, 3013868032, 3582836063, /* 118 */
    1651351356, 2220320582, 2789289565, 3358258282, 3927226931, /* 119 */
    1426844807, 1995818556, 2564791839, 3133764669, 3702737082, /* 120 */
    1771330386, 2340303879, 2909276776, 3478249215, 4047220951, /* 121 */
    1546738958, 2115712135, 2684685245, 3253658159, 3822630880, /* 122 */
    1322202084, 1891177438, 2460153012, 3029128796, 3598104624, /* 123 */
    1666695680, 2235668942, 2804642587, 3373616581, 3942590756, /* 124 */
    1442127319, 2011096471, 2580066134, 3149036396, 3718007217, /* 125 */
    1217586132, 1786556826, 2355527822, 2924499267, 3493471089, /* 126 */
    1562095447, 2131065636, 2700035870, 3269006123, 3837976483, /* 127 */
    1337558034, 1906525753, 2475493133, 3044460348, 3613427426, /* 128 */
    1681964276, 2250935541, 2819906536, 3388877165, 3957847660, /* 129 */
    1457488699, 2026462725, 2595436313, 3164409369, 3733381909, /* 130 */
    1232956785, 1801929648, 2370902167, 2939874210, 3508845811, /* 131 */
    1577337533, 2146312031, 2715286605, 3284261055, 3853235420, /* 132 */
    1352844775, 1921819897, 2490795327, 3059771020, 3628746828, /* 133 */
    1697306441, 2266277782, 2835249495, 3404221676, 3973194177, /* 134 */
    1472720882, 2041690768, 2610661150, 3179632137, 3748603685, /* 135 */
    1248230185, 1817201270, 2386172559, 2955144131, 3524116051, /* 136 */
    1592721675, 2161690375, 2730658919, 3299627432, 3868595973, /* 137 */
    1368145580, 1937114164, 2506082399, 3075050546, 3644018476, /* 138 */
    1712600309, 2281573050, 2850545400, 3419517415, 3988489034, /* 139 */
    1488120873, 2057094354, 2626067299, 3195039666, 3764011482, /* 140 */
    1263539259, 1832512139, 2401484786, 2970457223, 3539429220, /* 141 */
    1607962479, 2176938010, 2745913672, 3314889364, 3883864936, /* 142 */
    1383482856, 1952456851, 2521431228, 3090405823, 3659380668, /* 143 */
    1727894773, 2296864842, 2865835450, 3434806544, 4003778175, /* 144 */
    1503340000, 2072311006, 2641282449, 3210254428, 3779226923, /* 145 */
    1278876878, 1847847400, 2416818073, 2985788766, 3554759781, /* 146 */
    1623321787, 2192289174, 2761256415, 3330223544, 3899190724, /* 147 */
    1398751473, 1967722002, 2536692170, 3105662199, 3674632034, /* 148 */
    1743245316, 2312218669, 2881191409, 3450163813, 4019135671, /* 149 */
    1518727953, 2087700409, 2656672420, 3225643831, 3794614688, /* 150 */
    1294131102, 1863105228, 2432079198, 3001053146, 3570026796, /* 151 */
    1638603278, 2207579026, 2776554875, 3345530847, 3914506743, /* 152 */
    1414100739, 1983072853, 2552045453, 3121018350, 3689991535, /* 153 */
    1758483784, 2327454109, 2896425130, 3465396681, 4034368885, /* 154 */
    1533980848, 2102952345, 2671924174, 3240896360, 3809868996, /* 155 */
    1309509570, 1878478639, 2447447777, 3016416857, 3585386081, /* 156 */
};
