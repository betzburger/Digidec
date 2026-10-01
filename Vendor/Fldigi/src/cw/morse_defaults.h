// ----------------------------------------------------------------------------
// morse_defaults.h  --  Digidec: die fldigi-Einstellungen, die die Morsetabelle (morse.cpp) liest
// Standardwerte wie fldigi configuration.h (Umlaute Ä Ö Ü an, Prosigns =~<>%+&{}).
// ----------------------------------------------------------------------------
#ifndef DIGIDEC_MORSE_DEFAULTS_H
#define DIGIDEC_MORSE_DEFAULTS_H
#include <string>

struct MorseProgdefaults {
	std::string CW_prosigns = "=~<>%+&{}";
	bool CW_prosign_display = false;
	bool A_umlaut = true,  A_aelig = false, A_ring = true,  C_cedilla = true;
	bool E_grave = true,   E_acute = true,  O_acute = false, O_umlaut = true;
	bool O_slash = false,  N_tilde = true,  U_umlaut = true, U_circ = false;
	bool CW_backslash = true, CW_apostrophe = true, CW_quote = true, CW_dollar_sign = true;
	bool CW_open_paren = true, CW_close_paren = true, CW_colon = true, CW_semi_colon = true;
	bool CW_underscore = true, CW_at_symbol = true, CW_exclamation = true;
};

/// in morse.cpp nur unter diesem Namen benutzt (fldigi: globales progdefaults)
extern MorseProgdefaults progdefaults;

#endif
