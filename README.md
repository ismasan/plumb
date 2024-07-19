# Plumb

**This library is work in progress!**

Composable data validation, coercion and processing in Ruby. Takes over from https://github.com/ismasan/parametric

This library takes ideas from the excellent https://dry-rb.org ecosystem, with some of the features offered by Dry-Types, Dry-Schema, Dry-Struct. However, I'm aiming at a subset of the functionality with a (hopefully) smaller API surface and fewer concepts, focusing on lessons learned after using Parametric in production for many years.

If you're after raw performance and versatility I strongly recommend you use the Dry gems.

For a description of the core architecture you can read [this article](https://ismaelcelis.com/posts/composable-pipelines-in-ruby/).

## Installation

Install in your environment with `gem install plumb`, or in your `Gemfile` with

```ruby
gem 'plumb'
```

## Usage

### Include base types.

Include base types in your own namespace:

```ruby
module Types
  # Include Plumb base types, such as String, Integer, Boolean
  include Plumb::Types
  
  # Define your own types
  Email = String[/@/]
end

# Use them
result = Types::String.resolve("hello")
result.valid? # true
result.errors # nil

result = Types::Email.resolve("foo")
result.valid? # false
result.errors # ""
```

Note that this is not mandatory. You can also work with the `Plumb::Types` module directly, ex. `Plumb::Types::String`

### Specialize your types with `#[]`

Use `#[]` to make your types match a class.

```ruby
module Types
  include Plumb::Types
  
  String = Types::Any[::String]
  Integer = Types::Any[::Integer]
end

Types::String.parse("hello") # => "hello"
Types::String.parse(10) # raises "Must be a String" (Plumb::TypeError)
```

Plumb ships with basic types already defined, such as `Types::String` and `Types::Integer`. See the full list below.

The `#[]` method is not just for classes. It works with anything that responds to `#===`

```ruby
# Match against a regex
Email = Types::String[/@/] # ie Types::Any[String][/@/]

Email.parse('hello') # fails
Email.parse('hello@server.com') # 'hello@server.com'

# Or a Range
AdultAge = Types::Integer[18..]
AdultAge.parse(20) # 20
AdultAge.parse(17) # raises "Must be within 18.."" (Plumb::TypeError)

# Or literal values
Twenty = Types::Integer[20]
Twenty.parse(20) # 20
Twenty.parse(21) # type error
```

It can be combined with other methods. For example to cast strings as integers, but only if they _look_ like integers.

```ruby
StringToInt = Types::String[/^\d+$/].transform(::Integer, &:to_i)

StringToInt.parse('100') # => 100
StringToInt.parse('100lol') # fails
```

### `#resolve(value) => Result`

`#resolve` takes an input value and returns a `Result::Valid` or `Result::Invalid`

```ruby
result = Types::Integer.resolve(10)
result.valid? # true
result.value # 10

result = Types::Integer.resolve('10')
result.valid? # false
result.value # '10'
result.errors # 'must be an Integer'
```

### `#parse(value) => value`

`#parse` takes an input value and returns the parsed/coerced value if successful. or it raises an exception if failed.

```ruby
Types::Integer.parse(10) # 10
Types::Integer.parse('10') # raises Plumb::TypeError
```



### Composite types

Some built-in types such as `Types::Array` and `Types::Hash` allow defininig array or hash data structures composed of other types.

```ruby
# A user hash
User = Types::Hash[name: Types::String, email: Email, age: AdultAge]

# An array of User hashes
Users = Types::Array[User]

joe = User.parse({ name: 'Joe', email: 'joe@email.com', age: 20}) # returns valid hash
Users.parse([joe]) # returns valid array of user hashes
```

More about [Types::Array](#typeshash) and [Types::Array](#typesarray). There's also tuples and hash maps, and it's possible to create your own composite types.

## Type composition

At the core, Plumb types are little [Railway-oriented pipelines](https://ismaelcelis.com/posts/composable-pipelines-in-ruby/) that can be composed together with _AND_, _OR_ and _NOT_ semantics. Everything else builds on top of these two ideas.

### Composing types with `#>>` ("And")

```ruby
Email = Types::String[/@/]
# You can compose procs and lambdas, or other types.
Greeting = Email >> ->(result) { result.valid("Your email is #{result.value}") }

Greeting.parse('joe@bloggs.com') # "Your email is joe@bloggs.com"
```

Similar to Ruby's built-in [function composition](https://thoughtbot.com/blog/proc-composition-in-ruby), `#>>` pipes the output of a "type" to the input of the next type. However, if a type returns an "invalid" result, the chain is halted there and subsequent steps are never run. 

In other words, `A >> B` means "if A succeeds, pass its result to B. Otherwise return A's failed result."

### Disjunction with `#|` ("Or")

`A | B` means "if A returns a valid result, return that. Otherwise try B with the original input."

```ruby
StringOrInt = Types::String | Types::Integer
StringOrInt.parse('hello') # "hello"
StringOrInt.parse(10) # 10
StringOrInt.parse({}) # raises Plumb::TypeError
```

Custom default value logic for non-emails

```ruby
EmailOrDefault = Greeting | Types::Static['no email']
EmailOrDefault.parse('joe@bloggs.com') # "Your email is joe@bloggs.com"
EmailOrDefault.parse('nope') # "no email"
```

## Composing with `#>>` and `#|`

Combine `#>>` and `#|` to compose branching workflows, or types that accept and output several possible data types.

`((A >> B) | C | D) >> E)`

This more elaborate example defines a combination of types which, when composed together with `>>` and `|`, can coerce strings or integers into Money instances with currency. It also shows some of the built-in [policies](#policies) or helpers.

```ruby
require 'money'

module Types
  include Plumb::Types
  
  # Match any Money instance
  Money = Any[::Money]
  
  # Transform Integers into Money instances
  IntToMoney = Integer.transform(::Money) { |v| ::Money.new(v, 'USD') }
  
  # Transform integer-looking Strings into Integers
  StringToInt = String.match(/^\d+$/).transform(::Integer, &:to_i)
  
  # Validate that a Money instance is USD
  USD = Money.check { |amount| amount.currency.code == 'UDS' }
  
  # Exchange a non-USD Money instance into USD
  ToUSD = Money.transform(::Money) { |amount| amount.exchange_to('USD') }
  
  # Compose a pipeline that accepts Strings, Integers or Money and returns USD money.
  FlexibleUSD = (Money | ((Integer | StringToInt) >> IntToMoney)) >> (USD | ToUSD)
end

FlexibleUSD.parse('1000') # Money(USD 10.00)
FlexibleUSD.parse(1000) # Money(USD 10.00)
FlexibleUSD.parse(Money.new(1000, 'GBP')) # Money(USD 15.00)
```

You can see more use cases in [the examples directory](https://github.com/ismasan/plumb/tree/main/examples)

## Built-in types

* `Types::Value`
* `Types::Array`
* `Types::True`
* `Types::Symbol`
* `Types::Boolean`
* `Types::Interface`
* `Types::False`
* `Types::Tuple`
* `Types::Split`
* `Types::Any`
* `Types::Static`
* `Types::Undefined`
* `Types::Nil`
* `Types::Integer`
* `Types::Numeric`
* `Types::String`
* `Types::Hash`
* `Types::Lax::Integer`
* `Types::Lax::String`
* `Types::Lax::Symbol`
* `Types::Forms::Boolean`
* `Types::Forms::Nil`
* `Types::Forms::True`
* `Types::Forms::False`



### Policies

Policies are helpers that encapsulate common compositions. Plumb ships with some handy ones, listed below, and you can also define your own.

### `#present`

Checks that the value is not blank (`""` if string, `[]` if array, `{}` if Hash, or `nil`)

```ruby
Types::String.present.resolve('') # Failure with errors
Types::Array[Types::String].resolve([]) # Failure with errors
```

### `#nullable`

Allow `nil` values.

```ruby
nullable_str = Types::String.nullable
nullable_srt.parse(nil) # nil
nullable_str.parse('hello') # 'hello'
nullable_str.parse(10) # TypeError
```

Note that this just encapsulates the following composition:

```ruby
nullable_str = Types::String | Types::Nil
```

### `#not`

Negates a type. 
```ruby
NotEmail = Types::Email.not

NotEmail.parse('hello') # "hello"
NotEmail.parse('hello@server.com') # error
```

### `#options`

Sets allowed options for value.

```ruby
type = Types::String.options(['a', 'b', 'c'])
type.resolve('a') # Valid
type.resolve('x') # Failure
```

For arrays, it checks that all elements in array are included in options.

```ruby
type = Types::Array.options(['a', 'b'])
type.resolve(['a', 'a', 'b']) # Valid
type.resolve(['a', 'x', 'b']) # Failure
```

### `#transform`

Transform value. Requires specifying the resulting type of the value after transformation.

```ruby
StringToInt = Types::String.transform(Integer) { |value| value.to_i }
# Same as
StringToInt = Types::String.transform(Integer, &:to_i)

StringToInteger.parse('10') # => 10
```

### `#invoke`

`#invoke` builds a Step that will invoke one or more methods on the value.

```ruby
StringToInt = Types::String.invoke(:to_i)
StringToInt.parse('100') # 100

FilteredHash = Types::Hash.invoke(:except, :foo, :bar)
FilteredHash.parse(foo: 1, bar: 2, name: 'Joe') # { name: 'Joe' }

# It works with blocks
Evens = Types::Array[Integer].invoke(:filter, &:even?)
Evens.parse([1,2,3,4,5]) # [2, 4]

# Same as
Evens = Types::Array[Integer].transform(Array) {|arr| arr.filter(&:even?) }
```

Passing an array of Symbol method names will build a chain of invocations.

```ruby
UpcaseToSym = Types::String.invoke(%i[downcase to_sym])
UpcaseToSym.parse('FOO_BAR') # :foo_bar
```

That that, as opposed to `#transform`, this modified does not register a type in `#metadata[:type]`, which can be valuable for introspection or documentation (ex. JSON Schema).

Also, there's no definition-time checks that the method names are actually supported by the input values.

```ruby
type = Types::Array.invoke(:strip) # This is fine here
type.parse([1, 2]) # raises NoMethodError because Array doesn't respond to #strip
```

Use with caution.

### `#default`

Default value when no value given (ie. when key is missing in Hash payloads. See `Types::Hash` below).

```ruby
str = Types::String.default('nope'.freeze)
str.parse() # 'nope'
str.parse('yup') # 'yup'
```

Note that this is syntax sugar for:

```ruby
# A String, or if it's Undefined pipe to a static string value.
str = Types::String | (Types::Undefined >> Types::Static['nope'.freeze])
```

Meaning that you can compose your own semantics for a "default" value.

Example when you want to apply a default when the given value is `nil`.

```ruby
str = Types::String | (Types::Nil >> Types::Static['nope'.freeze])

str.parse(nil) # 'nope'
str.parse('yup') # 'yup'
```

Same if you want to apply a default to several cases.

```ruby
str = Types::String | ((Types::Nil | Types::Undefined) >> Types::Static['nope'.freeze])
```

### `#build`

Build a custom object or class.

```ruby
User = Data.define(:name)
UserType = Types::String.build(User)

UserType.parse('Joe') # #<data User name="Joe">
```

It takes an argument for a custom factory method on the object constructor.

```ruby
# https://github.com/RubyMoney/monetize
require 'monetize'

StringToMoney = Types::String.build(Monetize, :parse)
money = StringToMoney.parse('£10,300.00') # #<Money fractional:1030000 currency:GBP>
```

You can also pass a block

```ruby
StringToMoney = Types::String.build(Money) { |value| Monetize.parse(value) }
```

Note that this case is identical to `#transform` with a block.

```ruby
StringToMoney = Types::String.transform(Money) { |value| Monetize.parse(value) }
```

### `#check`

Pass the value through an arbitrary validation

```ruby
type = Types::String.check('must start with "Role:"') { |value| value.start_with?('Role:') }
type.parse('Role: Manager') # 'Role: Manager'
type.parse('Manager') # fails
```



### `#value` 

Constrain a type to a specific value. Compares with `#==`

```ruby
hello = Types::String.value('hello')
hello.parse('hello') # 'hello'
hello.parse('bye') # fails
hello.parse(10) # fails 'not a string'
```

All scalar types support this:

```ruby
ten = Types::Integer.value(10)
```

### `#meta` and `#metadata`

Add metadata to a type

```ruby
type = Types::String.meta(description: 'A long text')
type.metadata[:description] # 'A long text'
```

`#metadata` combines keys from type compositions.

```ruby
type = Types::String.meta(description: 'A long text') >> Types::String.match(/@/).meta(note: 'An email address')
type.metadata[:description] # 'A long text'
type.metadata[:note] # 'An email address'
```

`#metadata` also computes the target type.

```ruby
Types::String.metadata[:type] # String
Types::String.transform(Integer, &:to_i).metadata[:type] # Integer
# Multiple target types for unions
(Types::String | Types::Integer).metadata[:type] # [String, Integer]
```

TODO: document custom visitors.

### Other policies

There's some other built-in "policies" that can be used via the `#policy` method. Helpers such as `#default` and `#present` are shortcuts for this and can also be used via `#policy(default: 'Hello')` or `#policy(:present)` See [custom policies](#custom-policies) for how to define your own policies.

#### `:respond_to`

Similar to `Types::Interface`, this is a quick way to assert that a value supports one or more methods.

```ruby
List = Types::Any.policy(respond_to: :each)
# or
List = Types::Any.policy(respond_to: [:each, :[], :size)
```

#### `:excluded_from`

The opposite of `#options`, this policy validates that the value _is not_ included in a list.

```ruby
Name = Types::String.policy(excluded_from: ['Joe', 'Joan'])
```

#### `:size`

Works for any value that responds to `#size` and validates that the value's size matches the argument.

```ruby
LimitedArray = Types::Array[String].policy(size: 10)
LimitedString = Types::String.policy(size: 10)
LimitedSet = Types::Any[Set].policy(size: 10)
```

The size is matched via `#===`, so ranges also work.

```ruby
Password = Types::String.policy(size: 10..20)
```

#### `:split` (strings only)

Splits string values by a separator (default: `,`).

```ruby
CSVLine = Types::String.split
CSVLine.parse('a,b,c') # => ['a', 'b', 'c']

# Or, with custom separator
CSVLine = Types::String.split(/\s*;\s*/)
CSVLine.parse('a;b;c') # => ['a', 'b', 'c']
```



### `Types::Hash`

```ruby
Employee = Types::Hash[
  name: Types::String.present,
  age?: Types::Lax::Integer,
  role: Types::String.options(%w[product accounts sales]).default('product')
]

Company = Types::Hash[
  name: Types::String.present,
  employees: Types::Array[Employee]
]

result = Company.resolve(
  name: 'ACME',
  employees: [
    { name: 'Joe', age: 40, role: 'product' },
    { name: 'Joan', age: 38, role: 'engineer' }
  ]
)

result.valid? # true

result = Company.resolve(
  name: 'ACME',
  employees: [{ name: 'Joe' }]
)

result.valid? # false
result.errors[:employees][0][:age] # ["must be a Numeric"]
```

Note that you can use primitives as hash field definitions.

```ruby
User = Types::Hash[name: String, age: Integer]
```

Or to validate specific values:

```ruby
Joe = Types::Hash[name: 'Joe', age: Integer]
```

Or to validate against any `#===` interface:

```ruby
Adult = Types::Hash[name: String, age: (18..)]
# Same as
Adult = Types::Hash[name: Types::String, age: Types::Integer[18..]]
```

If you want to validate literal values, pass a `Types::Value`

```ruby
Settings = Types::Hash[age_range: Types::Value[18..]]

Settings.parse(age_range: (18..)) # Valid
Settings.parse(age_range: (20..30)) # Invalid
```

A `Types::Static` value will always resolve successfully to that value, regardless of the original payload.

```ruby
User = Types::Hash[name: Types::Static['Joe'], age: Integer]
User.parse(name: 'Rufus', age: 34) # Valid {name: 'Joe', age: 34}
```

#### Optional keys

Keys suffixed with `?` are marked as optional and its values will only be validated and coerced if the key is present in the input hash.

```ruby
User = Types::Hash[
  age?: Integer,
  name: String
]

User.parse(age: 20, name: 'Joe') # => Valid { age: 20, name: 'Joe' }
User.parse(age: '20', name: 'Joe') # => Invalid, :age is not an Integer
User.parse(name: 'Joe') #=> Valid { name: 'Joe' }
```

Note that defaults are not applied to optional keys that are missing.

```ruby
Types::Hash[
  age?: Types::Integer.default(10), # does not apply default if key is missing  
  name: Types::String.default('Joe') # does apply default if key is missing.
]
```

#### Merging hash definitions

Use `Types::Hash#+` to merge two definitions. Keys in the second hash override the first one's.

```ruby
User = Types::Hash[name: Types::String, age: Types::Integer]
Employee = Types::Hash[name: Types::String, company: Types::String]
StaffMember = User + Employee # Hash[:name, :age, :company]
```

#### Hash intersections

Use `Types::Hash#&` to produce a new Hash definition with keys present in both.

```ruby
intersection = User & Employee # Hash[:name]
```

#### `Types::Hash#tagged_by`

Use `#tagged_by` to resolve what definition to use based on the value of a common key.

Key used as index must be a `Types::Static`

```ruby
NameUpdatedEvent = Types::Hash[type: Types::Static['name_updated'], name: Types::String]
AgeUpdatedEvent = Types::Hash[type: Types::Static['age_updated'], age: Types::Integer]

Events = Types::Hash.tagged_by(
  :type,
  NameUpdatedEvent,
  AgeUpdatedEvent
)

Events.parse(type: 'name_updated', name: 'Joe') # Uses NameUpdatedEvent definition
```

#### `Types::Hash#inclusive`

Use `#inclusive` to preserve input keys not defined in the hash schema.

```ruby
hash = Types::Hash[age: Types::Lax::Integer].inclusive

# Only :age, is coerced and validated, all other keys are preserved as-is
hash.parse(age: '30', name: 'Joe', last_name: 'Bloggs') # { age: 30, name: 'Joe', last_name: 'Bloggs' }
```

This can be useful if you only care about validating some fields, or to assemble different front and back hashes. For example a client-facing one that validates JSON or form data, and a backend one that runs further coercions or domain validations on some keys.

```ruby
# Front-end definition does structural validation
Front = Types::Hash[price: Integer, name: String, category: String]

# Turn an Integer into a Money instance
IntToMoney = Types::Integer.build(Money)

# Backend definition turns :price into a Money object, leaves other keys as-is
Back = Types::Hash[price: IntToMoney].inclusive

# Compose the pipeline
InputHandler = Front >> Back

InputHandler.parse(price: 100_000, name: 'iPhone 15', category: 'smartphones')
# => { price: #<Money fractional:100000 currency:GBP>, name: 'iPhone 15', category: 'smartphone' }
```

#### `Types::Hash#filtered`

The `#filtered` modifier returns a valid Hash with the subset of values that were valid, instead of failing the entire result if one or more values are invalid.

```ruby
User = Types::Hash[name: String, age: Integer]
User.parse(name: 'Joe', age: 40) # => { name: 'Joe', age: 40 }
User.parse(name: 'Joe', age: 'nope') # => { name: 'Joe' }
```

### Hash maps

You can also use Hash syntax to define a hash map with specific types for all keys and values:

```ruby
currencies = Types::Hash[Types::Symbol, Types::String]

currencies.parse(usd: 'USD', gbp: 'GBP') # Ok
currencies.parse('usd' => 'USD') # Error. Keys must be Symbols
```

Like other types, hash maps accept primitive types as keys and values:

```ruby
currencies = Types::Hash[Symbol, String]
```

And any `#===` interface as values, too:

```ruby
names_and_emails = Types::Hash[String, /\w+@\w+/]

names_and_emails.parse('Joe' => 'joe@server.com', 'Rufus' => 'rufus')
```

Use `Types::Value` to validate specific values (using `#==`)

```ruby
names_and_ones = Types::Hash[String, Types::Integer.value(1)]
```

#### `#filtered`

Calling the `#filtered` modifier on a Hash Map makes it return a sub set of the keys and values that are valid as per the key and value type definitions.

```ruby
# Filter the ENV for all keys starting with S3_*
S3Config = Types::Hash[/^S3_\w+/, Types::Any].filtered

S3Config.parse(ENV.to_h) # { 'S3_BUCKET' => 'foo', 'S3_REGION' => 'us-east-1' }
```



### `Types::Array`

```ruby
names = Types::Array[Types::String.present]
names_or_ages = Types::Array[Types::String.present | Types::Integer[21..]]
```

Arrays support primitive classes, or any `#===` interface:

```ruby
strings = Types::Array[String]
emails = Types::Array[/@/]
# Similar to 
emails = Types::Array[Types::String[/@/]]
```

Prefer the latter (`Types::Array[Types::String[/@/]]`), as that first validates that each element is a `String` before matching agains the regular expression.

#### Concurrent arrays

Use `Types::Array#concurrent` to process array elements concurrently (using Concurrent Ruby for now).

```ruby
ImageDownload = Types::URL >> ->(result) { 
  resp = HTTP.get(result.value)
  if (200...300).include?(resp.status)
    result.valid(resp.body)
  else
    result.invalid(error: resp.status)
  end
}
Images = Types::Array[ImageDownload].concurrent

# Images are downloaded concurrently and returned in order.
Images.parse(['https://images.com/1.png', 'https://images.com/2.png'])
```

TODO: pluggable concurrency engines (Async?)

#### `#stream`

Turn an Array definition into an enumerator that yields each element wrapped in `Result::Valid` or `Result::Invalid`.

See `Types::Stream` below for more.

#### `#filtered`

The `#filtered` modifier makes an array definition return a subset of the input array where the values are valid, as per the array's element type.

```ruby
j_names = Types::Array[Types::String[/^j/]].filtered
j_names.parse(%w[james ismael joe toby joan isabel]) # ["james", "joe", "joan"]
```



### `Types::Tuple`

```ruby
Status = Types::Symbol.options(%i[ok error])
Result = Types::Tuple[Status, Types::String]

Result.parse([:ok, 'all good']) # [:ok, 'all good']
Result.parse([:ok, 'all bad', 'nope']) # type error
```

Note that literal values can be used too.

```ruby
Ok = Types::Tuple[:ok, nil]
Error = Types::Tuple[:error, Types::String.present]
Status = Ok | Error
```

... Or any `#===` interface

```ruby
NameAndEmail = Types::Tuple[String, /@/]
```

As before, use `Types::Value` to check against literal values using `#==`

```ruby
NameAndRegex = Types::Tuple[String, Types::Value[/@/]]
```



### `Types::Stream`

`Types::Stream` defines an enumerator that validates/coerces each element as it iterates.

This example streams a CSV file and validates rows as they are consumed.

```ruby
require 'csv'

Row = Types::Tuple[Types::String.present, Types:Lax::Integer]
Stream = Types::Stream[Row]

data = CSV.new(File.new('./big-file.csv')).each # An Enumerator
# stream is an Enumerator that yields rows wrapped in[Result::Valid] or [Result::Invalid]
stream = Stream.parse(data)
stream.each.with_index(1) do |result, line|
  if result.valid?
    p result.value
  else
    p ["row at line #{line} is invalid: ", result.errors]
  end
end
```

#### `Types::Stream#filtered`

Use `#filtered` to turn a `Types::Stream` into a stream that only yields valid elements.

```ruby
ValidElements = Types::Stream[Row].filtered
ValidElements.parse(data).each do |valid_row|
  p valid_row
end
```

#### `Types::Array#stream`

A `Types::Array` definition can be turned into a stream.

```ruby
Arr = Types::Array[Integer]
Str = Arr.stream

Str.parse(data).each do |row|
  row.valid?
  row.errors
  row.value
end
```

### Plumb::Schema

TODO

### Plumb::Pipeline

TODO

### Plumb::Struct

TODO

### Recursive types

You can use a proc to defer evaluation of recursive definitions.

```ruby
LinkedList = Types::Hash[
  value: Types::Any,
  next: Types::Nil | proc { |result| LinkedList.(result) }
]

LinkedList.parse(
  value: 1, 
  next: { 
    value: 2, 
    next: { 
      value: 3, 
      next: nil 
    }
  }
)
```

You can also use `#defer`

```ruby
LinkedList = Types::Hash[
  value: Types::Any,
  next: Types::Any.defer { LinkedList } | Types::Nil
]
```



### Custom types

Every Plumb type exposes the following one-method interface:

```
#call(Result::Valid) => Result::Valid | Result::Invalid
```

As long as an object implements this interface, it can be composed into Plumb workflows.

The `Result::Valid` class has helper methods `#valid(value) => Result::Valid` and `#invalid(errors:) => Result::Invalid` to facilitate returning valid or invalid values from your own steps.

Compose procs or lambdas directly

```ruby
Greeting = Types::String >> ->(result) { result.valid("Hello #{result.value}") }
```

or a custom class that responds to `#call(Result::Valid) => Result::Valid | Result::Invalid`

```ruby
class Greeting
  def initialize(gr = 'Hello')
    @gr = gr
  end

  # The Plumb Step interface
  # @param result [Plumb::Result::Valid]
  # @return [Plumb::Result::Valid, Plumb::Result::Invalid]
  def call(result)
    result.valid("#{gr} #{result.value}")
  end
end

MyType = Types::String >> Greeting.new('Hola')
```



### Custom policies

`Plumb.policy` can be used to encapsulate common type compositions, or compositions that can be configurable by parameters.

This example defines a `:default_if_nil` policy that returns a default if the value is `nil`.

```ruby
Plumb.policy :default_if_nil do |type, default_value|
  type | (Types::Nil >> Types::Static[default_value])
end
```

It can be used for any of your own types.

```ruby
StringWithDefault = Types::String.policy(default_if_nil: 'nothing here')
StringWithDefault.parse('hello') # 'hello'
StringWithDefault.parse(nil) # 'nothing here'
```

The `#policy` helper supports applying multiply policies.

```ruby
Types::String.policy(default_if_nil: 'nothing here', size: (10..20))
```

#### Policies as helper methods

Use the `helper: true` option to register the policy as a method you can call on types directly.

```ruby
Plumb.policy :default_if_nil, helper: true do |type, default_value|
  type | (Types::Nil >> Types::Static[default_value])
end

# Now use #default_if_nil directly
StringWithDefault = Types::String.default_if_nil('nothing here')
```

Many built-in helpers such as `#default` and `#options` are implemented as policies. This means that you can overwrite their default behaviour by defining a policy with the same name (use with caution!).

#### Type-specific policies

You can use the `for_type:` option to define policies that only apply to steps that output certain types. This example only applies for types that return `Integer` values.

```ruby
Plumb.policy :multiply_by, for_type: Integer, helper: true do |type, factor|
  type.invoke(:*, factor)
end

Doubled = Types::Integer.multiply_by(2)
Doubled.parse(2) # 4

# Tryin to apply this policy to a non Integer will raise an exception
DoubledString = Types::String.multiply_by(2) # raises error
```

#### Interface-specific policies

`for_type`also supports a Symbol for a method name, so that the policy can be applied to any types that support that method.

This example allows the `multiply_by` policy to work with any type that can be multiplied (by supporting the `:*` method).

```ruby
Plumb.policy :multiply_by, for_type: :*, helper: true do |type, factor|
  type.invoke(:*, factor)
end

# Now it works with anything that can be multiplied.
DoubledNumeric = Types::Numeric.multiply_by(2)
DoubledMoney = Types::Any[Money].multiply_by(2)
```

#### Self-contained policy modules

You can register a module, class or module with a three-method interface as a policy. This is so that policies can have their own namespace if they need local constants or private methods. For example, this is how the `:split` policy for strings is defined.

```ruby
module SplitPolicy
  DEFAULT_SEPARATOR = /\s*,\s*/

  def self.call(type, separator = DEFAULT_SEPARATOR)
    type.transform(Array) { |v| v.split(separator) }
  end

  def self.for_type = ::String
  def self.helper = false
end

Plumb.policy :split, SplitPolicy
```

### JSON Schema

Plumb ships with a JSON schema visitor that compiles a type composition into a JSON Schema Hash.

```ruby
User = Types::Hash[
  name: Types::String,
  age: Types::Integer[21..]
]

json_schema = Plumb::JSONSchemaVisitor.call(User)

{
  '$schema'=>'https://json-schema.org/draft-08/schema#', 
  'type' => 'object', 
  'properties' => {
    'name' => {'type' => 'string'}, 
    'age' => {'type' =>'integer', 'minimum' => 21}
  }, 
  'required' =>['name', 'age']
}
```

The built-in JSON Schema generator handles most standard types and compositions. You can add or override handles on a per-type basis with:

```ruby
Plumb::JSONSchemaVisitor.on(:not) do |node, props|
  props.merge('not' => visit(node.step))
end

# Example
type = Types::Decimal.not
schema = Plumb::JSONSchemaVisitor.visit(type) # { 'not' => { 'type' => 'number' } }
```

#### JSON Schema handlers for custom policies

TODO. See `Plumb::JSONSchemaVisitor`.



## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ismasan/plumb.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
