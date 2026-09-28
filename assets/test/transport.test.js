import {test, expect} from "bun:test"
import {clearTransportFallback, LONG_POLL_FALLBACK_MS} from "../js/transport"

test("a new page forgets only Phoenix's remembered long-poll decision", () => {
  const values = new Map([
    ["phx:fallback:LongPoll", "true"],
    ["phx:nav-history-position", "3"],
    ["ravix.theme", "dark"],
  ])
  const browser = {sessionStorage: {removeItem: key => values.delete(key)}}
  clearTransportFallback(browser)
  expect([...values]).toEqual([["phx:nav-history-position", "3"], ["ravix.theme", "dark"]])
  clearTransportFallback(browser)
  expect(values.size).toBe(2)
  expect(LONG_POLL_FALLBACK_MS).toBe(10_000)
})

test("storage denial does not abort startup", () => {
  expect(() => clearTransportFallback({get sessionStorage() {throw new Error("denied")}})).not.toThrow()
  expect(() => clearTransportFallback({sessionStorage: {removeItem() {throw new Error("denied")}}})).not.toThrow()
})
