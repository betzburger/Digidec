// ----------------------------------------------------------------------------
// record_loader.cxx
//
// Copyright (C) 2013
//		Remi Chateauneu, F4ECW
//
// This file is part of fldigi.
//
// Fldigi is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Fldigi is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with fldigi.  If not, see <http://www.gnu.org/licenses/>.
// ----------------------------------------------------------------------------

// ABWEICHUNG fldigi (Digidec): nur der Ladeteil. Entfallen sind der FLTK-Dialog zur Anzeige und zum
// Herunterladen der Tabellen (DerivedRecordLst, createRecordLoader) sowie die Verwaltungsliste all_recs.

#include <cstring>
#include <cerrno>
#include <ctime>
#include <fstream>
#include <sstream>
#include <sys/stat.h>

#include "record_loader.h"
#include "debug.h"
#include "strutil.h"

static std::string s_data_dir;

void RecordLoaderInterface::SetDataDir( const std::string & data_dir )
{
	s_data_dir = data_dir;
	if( !s_data_dir.empty() && s_data_dir.back() != '/' ) s_data_dir += '/';
}

RecordLoaderInterface::RecordLoaderInterface() {}

RecordLoaderInterface::~RecordLoaderInterface() {}

/// Loads a file and stores it for later lookup.
int RecordLoaderInterface::LoadAndRegister()
{
	Clear();

	std::string filnam = storage_filename().first;

	time_t cntTim = time(NULL);
	LOG_INFO("Opening:%s", filnam.c_str());

	std::ifstream ifs( filnam.c_str() );

	/// Reuse the same string for each new record.
	std::string input_str ;
	size_t nbRec = 0 ;
	while( ! ifs.eof() )
	{
		if( ! std::getline( ifs, input_str ) ) break;

		/// Comments are legal with # as first character.
		if( input_str[0] == '#' ) continue;

		imemstream str_strm( input_str );
		try
		{
			if( ReadRecord( str_strm ) ) {
				++nbRec;
			} else {
				LOG_WARN( "Cannot process '%s'", input_str.c_str() );
			}
		}
		catch(const std::exception & exc)
		{
			LOG_WARN( "%s: Caught <%s> when reading '%s'",
				base_filename().c_str(),
				exc.what(),
				input_str.c_str() );
			return -1 ;
		}
	}
	ifs.close();
	LOG_INFO( "Read:%s with %d records in %d seconds",
		filnam.c_str(), static_cast<int>(nbRec),
		static_cast<int>( time(NULL) - cntTim ) );
	return nbRec ;
}

/// This takes only the filename from the complete HTTP or FTP URL, or file path.
std::string RecordLoaderInterface::base_filename() const
{
	const char * pFil = strrchr( Url(), '/' );
	if( pFil == NULL )
		pFil =  Url();
	else
		++pFil ;

	/// This might be an URL so we take only the beginning.
	const char * quest = strchr( pFil, '?' );
	if( quest == NULL ) quest = pFil + strlen(pFil);
	return std::string( pFil, quest );
}

// ABWEICHUNG fldigi (Digidec): Die Stationslisten liegen im App-Bundle (SetDataDir); kein Anlegen von
// Verzeichnissen, kein Rückgriff auf PKGDATADIR, kein Download.
std::pair< std::string, bool > RecordLoaderInterface::storage_filename(bool) const
{
	std::string filnam_data = s_data_dir;
	filnam_data.append(base_filename());
	return std::make_pair( filnam_data, true );
}

std::string RecordLoaderInterface::Timestamp() const
{
	std::string filnam = storage_filename().first;

	struct stat st;
	if (stat(filnam.c_str(), &st) == -1 ) return "N/A";

	struct tm tmLastMod = *localtime( & st.st_mtime );

	char buf[64];
	snprintf(buf, sizeof(buf), "%d/%d/%d %02d:%02d",
			tmLastMod.tm_year + 1900,
			tmLastMod.tm_mon + 1,
			tmLastMod.tm_mday,
			tmLastMod.tm_hour,
			tmLastMod.tm_min );

	return buf ;
}

std::string RecordLoaderInterface::ContentSize() const
{
	/// It would be faster to cache this result in the object.
	std::string filnam = storage_filename().first;

	struct stat st;
	if (stat(filnam.c_str(), &st) == -1 ) return "      N/A";

	std::stringstream buf;
	buf.width(9); buf.fill(' ');
	buf <<  st.st_size;
	return buf.str();
}
