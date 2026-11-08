#include "config.h"
#include "LegacyExtensionResponseFilter.h"

namespace WebKit {

using namespace WebCore;

void LegacyExtensionResponseFilter::attach(uint64_t filterID)
{
    ASSERT(canAttach());
    m_stages.insert(0, Stage { filterID });
}

Vector<uint64_t> LegacyExtensionResponseFilter::filterIDs() const
{
    return m_stages.map([](auto& stage) {
        return stage.filterID;
    });
}

std::optional<size_t> LegacyExtensionResponseFilter::stageIndex(uint64_t filterID) const
{
    for (size_t index = 0; index < m_stages.size(); ++index) {
        if (m_stages[index].filterID == filterID)
            return index;
    }
    return std::nullopt;
}

void LegacyExtensionResponseFilter::receive(Ref<SharedBuffer>&& data)
{
    m_hasInput = true;
    if (!data->isEmpty())
        deliver(0, WTF::move(data));
}

void LegacyExtensionResponseFilter::finishInput()
{
    m_hasInput = true;
    finish(0);
}

void LegacyExtensionResponseFilter::start(Stage& stage)
{
    stage.state = State::Transferring;
    m_sendEvent(stage.filterID, "start"_s, nullptr, { });
}

void LegacyExtensionResponseFilter::sendData(Stage& stage, Ref<SharedBuffer>&& data)
{
    stage.undispatched.append(data.copyRef());
    m_sendEvent(stage.filterID, "data"_s, WTF::move(data), { });
}

void LegacyExtensionResponseFilter::stop(Stage& stage)
{
    stage.state = State::Finished;
    m_sendEvent(stage.filterID, "stop"_s, nullptr, { });
}

void LegacyExtensionResponseFilter::acknowledge(Stage& stage, uint64_t dispatched)
{
    while (stage.dispatchedCount < dispatched && !stage.undispatched.isEmpty()) {
        stage.undispatched.removeFirst();
        ++stage.dispatchedCount;
    }
}

void LegacyExtensionResponseFilter::deliver(size_t index, Ref<SharedBuffer>&& data)
{
    if (index == m_stages.size()) {
        if (!m_hasFinishedOutput)
            m_output(WTF::move(data));
        return;
    }
    auto& stage = m_stages[index];
    switch (stage.state) {
    case State::Waiting:
        start(stage);
        sendData(stage, WTF::move(data));
        return;
    case State::Transferring:
        sendData(stage, WTF::move(data));
        return;
    case State::Suspended:
        stage.queuedInput.append(WTF::move(data));
        return;
    case State::Finished:
    case State::Closed:
        return;
    case State::Disconnected:
    case State::Failed:
        deliver(index + 1, WTF::move(data));
        return;
    }
}

void LegacyExtensionResponseFilter::finish(size_t index)
{
    if (index == m_stages.size()) {
        if (!m_hasFinishedOutput) {
            m_hasFinishedOutput = true;
            m_output(nullptr);
        }
        return;
    }
    auto& stage = m_stages[index];
    stage.inputFinished = true;
    switch (stage.state) {
    case State::Waiting:
        start(stage);
        stop(stage);
        return;
    case State::Transferring:
        stop(stage);
        return;
    case State::Suspended:
    case State::Finished:
    case State::Closed:
        return;
    case State::Disconnected:
    case State::Failed:
        finish(index + 1);
        return;
    }
}

void LegacyExtensionResponseFilter::write(uint64_t filterID, Ref<SharedBuffer>&& data, uint64_t dispatched)
{
    auto index = stageIndex(filterID);
    if (!index)
        return;
    auto& stage = m_stages[*index];
    acknowledge(stage, dispatched);
    if ((stage.state == State::Transferring || stage.state == State::Suspended || stage.state == State::Finished) && !data->isEmpty())
        deliver(*index + 1, WTF::move(data));
}

void LegacyExtensionResponseFilter::close(uint64_t filterID)
{
    auto index = stageIndex(filterID);
    if (!index)
        return;
    auto& stage = m_stages[*index];
    if (stage.state == State::Closed || stage.state == State::Disconnected || stage.state == State::Failed)
        return;
    stage.state = State::Closed;
    stage.queuedInput.clear();
    stage.undispatched.clear();
    finish(*index + 1);
}

void LegacyExtensionResponseFilter::disconnect(uint64_t filterID, uint64_t dispatched)
{
    auto index = stageIndex(filterID);
    if (!index)
        return;
    auto& stage = m_stages[*index];
    if (stage.state == State::Closed || stage.state == State::Disconnected || stage.state == State::Failed)
        return;
    acknowledge(stage, dispatched);
    stage.state = State::Disconnected;
    auto pending = std::exchange(stage.undispatched, { });
    for (auto& data : std::exchange(stage.queuedInput, { }))
        pending.append(WTF::move(data));
    bool inputFinished = stage.inputFinished;
    for (auto& data : pending)
        deliver(*index + 1, WTF::move(data));
    if (inputFinished)
        finish(*index + 1);
}

void LegacyExtensionResponseFilter::suspend(uint64_t filterID)
{
    auto index = stageIndex(filterID);
    if (index && m_stages[*index].state == State::Transferring)
        m_stages[*index].state = State::Suspended;
}

void LegacyExtensionResponseFilter::resume(uint64_t filterID)
{
    auto index = stageIndex(filterID);
    if (!index)
        return;
    auto& stage = m_stages[*index];
    if (stage.state != State::Suspended)
        return;
    stage.state = State::Transferring;
    for (auto& data : std::exchange(stage.queuedInput, { }))
        sendData(stage, WTF::move(data));
    if (stage.inputFinished)
        stop(stage);
}

void LegacyExtensionResponseFilter::fail(const String& error)
{
    m_hasFinishedOutput = true;
    for (auto& stage : m_stages) {
        if (stage.state == State::Closed || stage.state == State::Disconnected || stage.state == State::Failed)
            continue;
        stage.state = State::Failed;
        stage.queuedInput.clear();
        stage.undispatched.clear();
        m_sendEvent(stage.filterID, "error"_s, nullptr, error);
    }
}

} // namespace WebKit
