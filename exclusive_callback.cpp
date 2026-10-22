#include "ai.h"
#include "exclusive_callback.h"

ExclusiveCallback::ExclusiveCallback(const std::string & description, size_t) :
    description(description)
{
}

ExclusiveCallback::~ExclusiveCallback()
{
}
