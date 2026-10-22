// Syntax/compile target only. No journal is created or replayed by this file.
#include "../installer/ProtectedJournalFile.h"
#include <type_traits>
static_assert(!std::is_copy_constructible_v<linghe::installer::recovery::ProtectedJournalFile>);
