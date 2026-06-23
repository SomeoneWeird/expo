import ExpoModulesCore
import ActivityKit
import WidgetKit

let pushNotificationsEnabledKey: String = "ExpoWidgets_EnablePushNotifications"

let onUserInteraction = "onExpoWidgetsUserInteraction"
let onPushToStartTokenReceived = "onExpoWidgetsPushToStartTokenReceived"
let onTokenReceived = "onExpoWidgetsTokenReceived"
let onUserInteractionNotification = Notification.Name(onUserInteraction)

/// Parses a live activity content-state `props` JSON string into a dictionary for event payloads.
/// Returns `nil` when the string is absent or not valid JSON object.
func parseLiveActivityProps(_ props: String?) -> [String: Any]? {
  guard let data = props?.data(using: .utf8) else { return nil }
  return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

public final class WidgetsModule: Module {
  var pushToStartTokenObserverTask: Task<Void, Never>?
  var activityUpdatesObserverTask: Task<Void, Never>?
  var activityPushTokenObserverTasks: [String: Task<Void, Never>] = [:]

  public func definition() -> ModuleDefinition {
    Name("ExpoWidgets")

    Events(onPushToStartTokenReceived, onTokenReceived, onUserInteraction)

    OnStartObserving(onUserInteraction) {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleUserInteractionNotification),
        name: onUserInteractionNotification,
        object: nil
      )
    }

    OnStopObserving(onUserInteraction) {
      NotificationCenter.default.removeObserver(
        self,
        name: onUserInteractionNotification,
        object: nil
      )
    }

    OnStartObserving(onPushToStartTokenReceived) {
      if pushNotificationsEnabled {
        observePushToStartToken()
      }
    }

    OnStopObserving(onPushToStartTokenReceived) {
      pushToStartTokenObserverTask?.cancel()
      pushToStartTokenObserverTask = nil
    }

    OnStartObserving(onTokenReceived) {
      if pushNotificationsEnabled {
        observeActivityPushTokens()
      }
    }

    OnStopObserving(onTokenReceived) {
      activityUpdatesObserverTask?.cancel()
      activityUpdatesObserverTask = nil
      for task in activityPushTokenObserverTasks.values {
        task.cancel()
      }
      activityPushTokenObserverTasks.removeAll()
    }

    Constant("widgetsDirectory") { () -> String? in
      guard let appGroupIdentifier = WidgetsStorage.appGroupIdentifier,
            let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
        return nil
      }
      let directoryUrl = containerUrl.appendingPathComponent("ExpoWidgets", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: directoryUrl, withIntermediateDirectories: true)
        return directoryUrl.absoluteString
      } catch {
        return nil
      }
    }

    Function("reloadAllWidgets") {
      WidgetCenter.shared.reloadAllTimelines()
    }

    Class("Widget", WidgetObject.self) {
      Constructor { (name: String, layout: String, initialProps: [String: Any]?) in
        WidgetObject(name: name, layout: layout, initialProps: initialProps)
      }

      Function("reload") { (widget: WidgetObject) in
        widget.reload()
      }

      Function("updateTimeline") { (widget: WidgetObject, entries: [WidgetsJSTimelineEntry]) in
        try widget.updateTimeline(entries: entries)
      }

      Function("getTimeline") { (widget: WidgetObject) in
        try widget.getTimeline()
      }
    }

    Class("LiveActivityFactory", LiveActivityFactory.self) {
      Constructor { (name: String, layout: String) in
        LiveActivityFactory(name: name, layout: layout)
      }

      Function("start") { (liveActivity: LiveActivityFactory, props: String?, url: URL?) in
        try liveActivity.start(props: props, url: url)
      }

      Function("getInstances") { (liveActivity: LiveActivityFactory) in
        try liveActivity.getInstances()
      }
    }

    Class("LiveActivity", LiveActivity.self) {
      AsyncFunction("update") { (instance: LiveActivity, props: String?) in
        try await instance.update(props: props)
      }

      AsyncFunction("end") { (instance: LiveActivity, dismissalPolicy: LiveActivityDismissalPolicy?, afterDate: Date?, props: String?, contentDate: Date?) in
        try await instance.end(dismissalPolicy: dismissalPolicy, afterDate: afterDate, props: props, contentDate: contentDate)
      }

      AsyncFunction("getPushToken") { (instance: LiveActivity) in
        try instance.getPushToken()
      }
    }
  }

  @objc func handleUserInteractionNotification(_ notification: Notification) {
    guard let userInfo = notification.userInfo as? [String: Any],
          let eventData = userInfo["eventData"] as? [String: Any]
    else { return }
    self.sendEvent(onUserInteraction, eventData)
  }

  private func sendPushToStartToken(activityPushToStartToken: String) {
    sendEvent(
      onPushToStartTokenReceived,
      [
        "activityPushToStartToken": activityPushToStartToken
      ]
    )
  }

  private func observePushToStartToken() {
    guard #available(iOS 17.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    pushToStartTokenObserverTask = Task {
      let initialToken = (Activity<LiveActivityAttributes>.pushToStartToken?.reduce("") { $0 + String(format: "%02x", $1) })
      if let initialToken {
        sendPushToStartToken(activityPushToStartToken: initialToken)
      }

      for await data in Activity<LiveActivityAttributes>.pushToStartTokenUpdates {
        let token = data.reduce("") { $0 + String(format: "%02x", $1) }
        if token != initialToken {
          sendPushToStartToken(activityPushToStartToken: token)
        }
      }
    }
  }

  private func sendActivityPushToken(for activity: Activity<LiveActivityAttributes>, token: String) {
    var payload: [String: Any] = [
      "activityId": activity.id,
      "pushToken": token
    ]
    if let props = parseLiveActivityProps(activity.content.state.props) {
      payload["props"] = props
    }
    sendEvent(onTokenReceived, payload)
  }

  @available(iOS 16.1, *)
  private func observeActivityPushToken(for activity: Activity<LiveActivityAttributes>) {
    let id = activity.id
    guard activityPushTokenObserverTasks[id] == nil else { return }

    activityPushTokenObserverTasks[id] = Task { [weak self] in
      if let token = activity.pushToken?.reduce("", { $0 + String(format: "%02x", $1) }) {
        self?.sendActivityPushToken(for: activity, token: token)
      }
      for await data in activity.pushTokenUpdates {
        let token = data.reduce("") { $0 + String(format: "%02x", $1) }
        self?.sendActivityPushToken(for: activity, token: token)
      }
      self?.activityPushTokenObserverTasks[id] = nil
    }
  }

  // Observes per-activity push tokens for every live activity of this type, including
  // activities started remotely via push-to-start (which have no JS handle). Apps can
  // subscribe with `addLiveActivityPushTokenListener` instead of polling `getInstances`.
  private func observeActivityPushTokens() {
    guard #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    activityUpdatesObserverTask = Task { [weak self] in
      for activity in Activity<LiveActivityAttributes>.activities {
        self?.observeActivityPushToken(for: activity)
      }
      for await activity in Activity<LiveActivityAttributes>.activityUpdates {
        self?.observeActivityPushToken(for: activity)
      }
    }
  }

  private var pushNotificationsEnabled: Bool {
    Bundle.main.object(forInfoDictionaryKey: pushNotificationsEnabledKey) as? Bool ?? false
  }
}
