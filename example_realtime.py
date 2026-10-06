"""Receive live counts for gaze experiments. Run with the native app open."""
import argparse
import sys
from counter_client import CounterClient, CounterAPIError


def on_sample(sample):
    # Pass this dictionary to your gaze estimation / screen experiment code.
    print(f"{sample['received_at']}  {sample['counts']:>8} counts  "
          f"{sample['counts_per_second']:>10.1f} counts/s", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate", type=float, choices=[0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0], default=0.1)
    parser.add_argument("--seconds", type=float, default=10)
    args = parser.parse_args()
    client = CounterClient()
    started = False
    session = None
    result = 0
    try:
        with client.stream() as events:
            state = client.start(args.gate, args.seconds)
            started = True
            session = state["session_id"]
            for event in events:
                if event.get("session_id") != session:
                    continue
                if event["type"] == "sample":
                    on_sample(event)
                elif event["type"] == "status" and not event["running"]:
                    if event["error"]:
                        raise CounterAPIError(event["error"])
                    break
    except KeyboardInterrupt:
        pass
    except CounterAPIError as error:
        print(error, file=sys.stderr)
        result = 1
    finally:
        if started:
            try:
                if client.status()["session_id"] == session:
                    client.stop()
            except CounterAPIError as error:
                print(error, file=sys.stderr)
                result = 1
    return result


if __name__ == "__main__":
    sys.exit(main())
