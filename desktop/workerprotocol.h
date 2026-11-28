#pragma once

#include <QJsonObject>

namespace WorkerProtocol {
inline constexpr int version = 1;
inline constexpr auto versionField = "protocol_version";

inline bool supportsVersion(const QJsonObject &message)
{
    const auto value = message.value(versionField);
    return value.isUndefined() || (value.isDouble() && value.toDouble() == version);
}
}
