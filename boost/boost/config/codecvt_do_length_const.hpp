/**
 * @file   codecvt_do_length_const.hpp
 * @author Nat Goodspeed
 * @date   2014-10-02
 * @brief  Extract BOOST_CODECVT_DO_LENGTH_CONST from
 *         boost/detail/utf8_codecvt_facet.hpp.
 * 
 * $LicenseInfo:firstyear=2014&license=viewerlgpl$
 * Copyright (c) 2014, Linden Research, Inc.
 * $/LicenseInfo$
 */

#if ! defined(BOOST_CODECVT_DO_LENGTH_CONST_HPP)
#define BOOST_CODECVT_DO_LENGTH_CONST_HPP

// This file exists to centralize logic that used to be duplicated (badly)
// between boost/detail/utf8_codecvt_facet.hpp and
// boost/iostreams/detail/config/codecvt.hpp. Both need to know whether the
// first parameter to std::codecvt::do_length() should be a const or non-const
// reference. This depends on the standard library that defines std::codecvt.
// The answers should agree.
#if (defined(__clang_major__) &&                                    \
     (__clang_major__ == 5 && __clang_minor__ >= 1) ||              \
     (__clang_major__ > 5)) ||                                      \
    (defined(BOOST_RWSTD_VER) && BOOST_RWSTD_VER >= 0x04010300) ||  \
    defined(__MSL_CPP__) ||                                         \
    defined(__LIBCOMO__) ||                                         \
    (defined(__MACH__) && defined(__INTEL_COMPILER))
    #define BOOST_CODECVT_DO_LENGTH_CONST
#else
    #define BOOST_CODECVT_DO_LENGTH_CONST const
#endif


#endif /* ! defined(BOOST_CODECVT_DO_LENGTH_CONST_HPP) */
