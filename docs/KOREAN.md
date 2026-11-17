# Korean text

Wine brings no font with Hangul. On an iPhone set to Korean, Wine already
runs programs with a Korean locale (ko-KR, code page 949), but every program
that draws Korean text shows it as empty squares: launchers such as Battle.net
(its Qt window and its Chromium sign-in page), installers and Korean games.

## What Madeira does

| Part | Effect |
|---|---|
| Font | The bundled **Noto Sans KR** (SIL Open Font License 1.1) is copied into the prefix's `C:\windows\Fonts`. |
| Font names | `HKCU\Software\Wine\Fonts\Replacements` maps Malgun Gothic (맑은 고딕), Gulim (굴림), GulimChe, New Gulim, Dotum (돋움), DotumChe, Batang (바탕), BatangChe, Gungsuh (궁서), GungsuhChe and Noto Sans CJK KR onto Noto Sans KR. GDI and DirectWrite both read these replacements; Noto Sans CJK KR is the family Wine's DirectWrite fallback asks for Hangul. A replacement only applies while no real font of that name is installed. |

The locale is left alone.

## When it applies

`env.MADEIRA_KOREAN`, in `Documents/madeira.cfg` or in **Game details › This
game's config**:

| Value | Effect |
|---|---|
| (not set) | On when Wine's locale is Korean: `env.LC_ALL` or `LANG` start with `ko`, or, with neither set, the device's first preferred language is Korean. |
| `1` | Always on, for a Korean game on a phone set to another language. |
| `0` | Never. |

The font and the font names are written before the wineserver starts and stay
in the prefix afterwards. The log shows `[korean]` lines for each step.

## Known limits

- Batang and Gungsuh (serif) are mapped to the same sans-serif font.
- GulimChe, DotumChe, BatangChe and GungsuhChe are fixed-pitch fonts; Noto Sans
  KR is not, so text laid out in fixed columns can be slightly misaligned.
  A real font of that name in `C:\windows\Fonts` takes precedence.
- Only the Regular weight is bundled; bold is synthesised.
