// Stubbed for MAVERICKS_BACKPORT
#include "config.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "FullscreenTouchSecheuristic.h"

#include <wtf/MonotonicTime.h>

namespace WebKit {

double FullscreenTouchSecheuristic::scoreOfNextTouch(CGPoint location)
{
    Seconds now = MonotonicTime::now().secondsSinceEpoch();

    if (!m_lastTouchTime) {
        m_lastTouchTime = WTF::move(now);
        return 0;
    }

    Seconds deltaTime = now - m_lastTouchTime;
    m_lastTouchTime = now;

    return scoreOfNextTouch(location, deltaTime);
}

double FullscreenTouchSecheuristic::scoreOfNextTouch(CGPoint location, const Seconds& deltaTime)
{
    if (m_lastTouchLocation.x == -1 && m_lastTouchLocation.y ==  -1) {
        m_lastTouchLocation = WTF::move(location);
        return 0;
    }

    double coefficient = attenuationFactor(deltaTime);
    m_lastScore = coefficient * distanceScore(location, m_lastTouchLocation, deltaTime) + (1 - coefficient) * m_lastScore;
    m_lastTouchLocation = location;
    return m_lastScore;
}

void FullscreenTouchSecheuristic::reset()
{
    m_lastTouchTime = 0_s;
    m_lastTouchLocation = { -1, -1 };
    m_lastScore = 0;
}

double FullscreenTouchSecheuristic::distanceScore(const CGPoint& nextLocation, const CGPoint& lastLocation, const Seconds& deltaTime)
{
    double distance = sqrt(
        m_parameters.xWeight * pow(nextLocation.x - lastLocation.x, 2) +
        m_parameters.yWeight * pow(nextLocation.y - lastLocation.y, 2));
    double sizeFactor = sqrt(
        m_parameters.xWeight * pow(m_size.width, 2) +
        m_parameters.yWeight * pow(m_size.height, 2));
    double scaledDistance = distance / sizeFactor;
    if (scaledDistance <= m_parameters.gammaCutoff)
        return scaledDistance * (m_parameters.rampUpSpeed / deltaTime);

    double exponentialDistance = m_parameters.gammaCutoff + pow((scaledDistance - m_parameters.gammaCutoff) / (1 - m_parameters.gammaCutoff), m_parameters.gamma);
    return exponentialDistance * (m_parameters.rampUpSpeed / deltaTime);
}

double FullscreenTouchSecheuristic::attenuationFactor(Seconds delta)
{
    double normalizedTimeDelta = delta / m_parameters.rampDownSpeed;
    return std::max(std::min(normalizedTimeDelta * m_weight, 1.0), 0.0);
}

}
MAVERICKS_BACKPORT */
