import Slots from "../src/slots"

def main() -> Void
  Test.run([
    Test.test("no more slots are given than the limit, and a released one can be taken again") do
      slots = Slots.new()
      try Test.assert(Slots.take?(slots, 2), "first")
      try Test.assert(Slots.take?(slots, 2), "second")
      try Test.assert(not Slots.take?(slots, 2), "third")
      try Test.assert(not Slots.take?(slots, 2), "a refused take does not use a slot")
      Slots.release(slots)
      Test.assert(Slots.take?(slots, 2), "after a release")
    end,
  ])
end
