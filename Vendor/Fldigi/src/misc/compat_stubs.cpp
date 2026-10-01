// ----------------------------------------------------------------------------
// compat_stubs.cpp  --  Digidec: Ersatz für fldigi-Teile, die der SYNOP-Decoder nur am Rand braucht
//
// KML-Export (Google Earth) und Logbuch-Einträge (ADIF) sind in Digidec abgeschaltet
// (synop_callback::log_kml() / log_adif() liefern false); die Symbole müssen aber existieren.
// ----------------------------------------------------------------------------
#include <ctime>
#include <string>
#include "kmlserver.h"
#include "field_def.h"

void KmlServer::CustomDataT::Push( const char * k, const std::string & v )
{
	push_back( std::make_pair( std::string(k), v ) );
}

/// Null-Objekt: nimmt Broadcasts entgegen und verwirft sie
namespace {
struct NullKmlServer : public KmlServer {
	void Broadcast( const std::string &, time_t, const CoordinateT::Pair &, double,
	                const std::string &, const std::string &, const std::string &, const CustomDataT & ) override {}
	void Reset() override {}
	void InitParams( const std::string &, const std::string &, double, int, int, int ) override {}
	void ReloadKmlFiles() override {}
};
}

KmlServer * KmlServer::GetInstance(void)
{
	static NullKmlServer inst;
	return &inst;
}

QsoHelper::QsoHelper(int) : qso_rec(nullptr) {}
QsoHelper::~QsoHelper() {}
void QsoHelper::Push( ADIF_FIELD_POS, const std::string & ) {}

// Unverändert aus fldigi 4.2.13 src/kml/kmlserver.cxx
std::string KmlServer::Tm2Time( time_t tim ) {
	char bufTm[40];
	tm tmpTm;
	gmtime_r( &tim, & tmpTm );

	snprintf( bufTm, sizeof(bufTm), "%4d-%02d-%02d %02d:%02d",
			tmpTm.tm_year + 1900,
			tmpTm.tm_mon + 1,
			tmpTm.tm_mday,
			tmpTm.tm_hour,
			tmpTm.tm_min );
	return bufTm;
}

std::string KmlServer::Tm2Time( ) {
	return Tm2Time( time(NULL) );
}
