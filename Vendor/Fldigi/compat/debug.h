// Digidec: Ersatz für fldigis debug.h – Protokollmeldungen des SYNOP-Decoders werden verworfen
#ifndef DIGIDEC_DEBUG_H
#define DIGIDEC_DEBUG_H
#define LOG_VERBOSE(...) ((void)0)
#define LOG_DEBUG(...)   ((void)0)
#define LOG_INFO(...)    ((void)0)
#define LOG_WARN(...)    ((void)0)
#define LOG_ERROR(...)   ((void)0)
#define LOG_FILE_SOURCE(x)
namespace debug { enum { LOG_SYNOP, LOG_DATASOURCES }; }
#endif
