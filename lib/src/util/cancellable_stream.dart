import 'dart:async';

/// What a body run by [cancellableStream] checks after every wait
class CancelSignal {
  var cancelled = false;
  void Function()? _wake;

  set onCancel(void Function() wake) => _wake = wake;
}

/// The next piece of the input, fetched while the body hands on what finished
/// elsewhere. One piece at a time, so the input still goes at the body's pace
class InputAhead<S> {
  final StreamIterator<S> _iterator;
  final void Function() _wake;
  var _asked = false;
  bool? _more;
  Object? _error;
  StackTrace? _stack;

  InputAhead(this._iterator, this._wake);

  void ask() {
    if (_asked) {
      return;
    }
    _asked = true;
    unawaited(_iterator.moveNext().then((more) {
      _more = more;
      _wake();
    }, onError: (Object error, StackTrace stack) {
      _error = error;
      _stack = stack;
      _wake();
    }));
  }

  bool get arrived => _more != null || _error != null;

  /// The piece that arrived, or null at the end. The input's error is thrown
  S? take() {
    final error = _error;
    if (error != null) {
      Error.throwWithStackTrace(error, _stack!);
    }
    final more = _more!;
    _more = null;
    _asked = false;
    return more ? _iterator.current : null;
  }
}

/// The stream [body] writes, where a cancel ends it while the input is silent.
/// An `async*` generator honours a cancel only at its next `yield`, so the
/// input is read through a [StreamIterator], whose pending `moveNext` a cancel
/// completes, and the body's own wait is woken through [CancelSignal]
Stream<T> cancellableStream<S, T>(Stream<S> input,
    Stream<T> Function(StreamIterator<S> input, CancelSignal signal) body) {
  final iterator = StreamIterator<S>(input);
  final signal = CancelSignal();
  StreamSubscription<T>? inner;
  late final StreamController<T> controller;
  controller = StreamController<T>(
    // An async controller delivers a pause a microtask late, by which time the
    // body is past the event and a tar entry's content is already skipped
    sync: true,
    onListen: () {
      inner = body(iterator, signal).listen(controller.add,
          onError: controller.addError, onDone: () {
        // A body that failed part way has not read its input to the end
        unawaited(iterator.cancel());
        unawaited(controller.close());
      });
    },
    onPause: () => inner?.pause(),
    onResume: () => inner?.resume(),
    onCancel: () async {
      // Asked for first, so the yield the woken body reaches ends it
      final innerCancel = inner?.cancel();
      signal.cancelled = true;
      signal._wake?.call();
      await iterator.cancel();
      // What the body throws once its input is cut is the cancel's own doing
      await innerCancel?.catchError((Object _) {});
    },
  );
  return controller.stream;
}
