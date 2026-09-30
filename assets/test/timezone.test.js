import {describe, expect, test} from "bun:test"
import {browserTimeZone} from "../js/timezone"

const intlWith = resolved => ({DateTimeFormat: () => ({resolvedOptions: resolved})})

describe("browserTimeZone", () => {
  test("reports the zone the browser resolves", () => {
    expect(browserTimeZone(intlWith(() => ({timeZone: "Asia/Kolkata"})))).toBe("Asia/Kolkata")
  })

  test("reports nothing when the browser names no zone", () => {
    expect(browserTimeZone(intlWith(() => ({})))).toBe("")
  })

  test("reports nothing when Intl throws", () => {
    expect(browserTimeZone(intlWith(() => { throw new RangeError("no zone") }))).toBe("")
  })

  test("uses the real Intl by default", () => {
    expect(typeof browserTimeZone()).toBe("string")
  })
})
