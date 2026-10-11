import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

@Reducer
struct LicenseFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.inMemory("supacode.license")) var snapshot = LicenseSnapshot()
    var keyInput = ""
    var isBusy = false
    var errorMessage: String?
    var isPresented = false

    mutating func apply(_ update: LicenseSnapshot) {
      $snapshot.withLock { current in
        guard update.updateSequence >= current.updateSequence else { return }
        var update = update
        update.trialCreations = max(update.trialCreations, current.trialCreations)
        current = update
      }
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case loaded(Result<LicenseSnapshot, Error>)
    case activate
    case deactivate
    case refresh
    case completed(Result<LicenseSnapshot, Error>)
    case show
    case dismiss
    case snapshotUpdated(LicenseSnapshot)
    case buy
    case portal
  }

  private nonisolated enum CancelID: Hashable, Sendable { case periodicRefresh }
  @Dependency(LicenseClient.self) private var client
  @Dependency(AnalyticsClient.self) private var analytics
  @Dependency(URLOpenerClient.self) private var urlOpener
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .run { send in
            do { await send(.loaded(.success(try await client.load()))) } catch {
              await send(.loaded(.failure(error)))
            }
            await send(.refresh)
          },
          .run { [clock] send in
            while !Task.isCancelled {
              try await clock.sleep(for: .seconds(86_400))
              await send(.refresh)
            }
          }.cancellable(id: CancelID.periodicRefresh, cancelInFlight: true)
        )
      case .loaded(.success(let snapshot)), .snapshotUpdated(let snapshot):
        state.apply(snapshot)
        return .none
      case .loaded(.failure(let error)):
        state.errorMessage = error.localizedDescription
        return .none
      case .activate:
        guard !state.isBusy else { return .none }
        state.isBusy = true
        state.errorMessage = nil
        let key = state.keyInput
        return .run { send in
          do { await send(.completed(.success(try await client.activate(key)))) } catch {
            await send(.completed(.failure(error)))
          }
        }
      case .deactivate:
        guard !state.isBusy else { return .none }
        state.isBusy = true
        state.errorMessage = nil
        return .run { send in
          do { await send(.completed(.success(try await client.deactivate()))) } catch {
            await send(.completed(.failure(error)))
          }
        }
      case .refresh:
        guard !state.isBusy else { return .none }
        return .run { send in
          do { await send(.snapshotUpdated(try await client.refresh())) } catch {
            SupaLogger("License").warning("License refresh unavailable; retaining cached access.")
          }
        }
      case .completed(.success(let snapshot)):
        state.isBusy = false
        state.keyInput = ""
        state.apply(snapshot)
        analytics.capture(
          snapshot.entitlement == nil ? "license_deactivated" : "license_activated", nil)
        return .none
      case .completed(.failure(let error)):
        state.isBusy = false
        state.errorMessage = error.localizedDescription
        return .none
      case .show:
        state.isPresented = true
        return .run { send in
          do { await send(.loaded(.success(try await client.load()))) } catch {
            await send(.loaded(.failure(error)))
          }
        }
      case .dismiss:
        state.isPresented = false
        return .none
      case .buy:
        analytics.capture("license_checkout_opened", nil)
        urlOpener.open(URL(string: "https://license.supacode.sh/buy")!)
        return .none
      case .portal:
        urlOpener.open(URL(string: "https://license.supacode.sh/login")!)
        return .none
      case .binding:
        return .none
      }
    }
  }
}
