#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout, stdin, stderr
// to/from that console.  This is useful for debugging purposes, and is not
// intended to be used in release builds.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Takes a null-terminated char* encoded in UTF-8 and returns a std::wstring
// encoded in UTF-16. Returns an empty std::wstring on failure.
std::wstring Utf16FromUtf8(const char* utf8_string);

// Gets the command line arguments passed to the process, parsed the same way
// as the arguments passed to main() on other platforms.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
