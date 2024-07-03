# Plumb

Composable data validation and coercion in Ruby. WiP. Takes over from https://github.com/ismasan/parametric

This library takes ideas from the excellent https://dry-rb.org ecosystem, with some of the features offered by Dry-Types, Dry-Schema, Dry-Struct. However, I'm aiming at a subset of the functionality with a (hopefully) smaller API surface and fewer concepts, focusing on lessons learned after using Parametric in production for many years.

If you're after raw performance and versatility I strongly recommend you use the Dry gems.

For a description of the core architecture you can read [this article](https://ismaelcelis.com/posts/composable-pipelines-in-ruby/).

## Installation

TODO

## Usage

### Include base types

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
* `Types::Blank`
* `Types::Any`
* `Types::Static`
* `Types::Undefined`
* `Types::Nil`
* `Types::Present`
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

Note that this is syntax sugar for 

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



### `#match` and `#[]`

Checks the value against a regular expression (or anything that responds to `#===`).

```ruby
email = Types::String.match(/@/)
# Same as
email = Types::String[/@/]
email.parse('hello') # fails
email.parse('hello@server.com') # 'hello@server.com'
```

It can be combined with other methods. For example to cast strings as integers, but only if they _look_ like integers.

```ruby
StringToInt = Types::String[/^\d+$/].transform(::Integer, &:to_i)

StringToInt.parse('100') # => 100
StringToInt.parse('100lol') # fails
```

It can be used with other `#===` interfaces.

```ruby
AgeBracket = Types::Integer[21..45]

AgeBracket.parse(22) # 22
AgeBracket.parse(20) # fails

# With literal values
Twenty = Types::Integer[20]
Twenty.parse(20) # 20
Twenty.parse(21) # type error
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

## `Types::Hash`

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

```ruby
NameUpdatedEvent = Types::Hash[type: 'name_updated', name: Types::String]
AgeUpdatedEvent = Types::Hash[type: 'age_updated', age: Types::Integer]

Events = Types::Hash.tagged_by(
  :type,
  NameUpdatedEvent,
  AgeUpdatedEvent
)

Events.parse(type: 'name_updated', name: 'Joe') # Uses NameUpdatedEvent definition
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



### Plumb::Schema

TODO

### Plumb::Pipeline

TODO

### Plumb::Struct

TODO

## Composing types with `#>>` ("And")

```ruby
Email = Types::String.match(/@/)
Greeting = Email >> ->(result) { result.valid("Your email is #{result.value}") }

Greeting.parse('joe@bloggs.com') # "Your email is joe@bloggs.com"
```


## Disjunction with `#|` ("Or")

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

```ruby
require 'money'

module Types
  include Plumb::Types
  
  Money = Any[::Money]
  IntToMoney = Integer.transform(::Money) { |v| ::Money.new(v, 'USD') }
  StringToInt = String.match(/^\d+$/).transform(::Integer, &:to_i)
  USD = Money.check { |amount| amount.currency.code == 'UDS' }
  ToUSD = Money.transform(::Money) { |amount| amount.exchange_to('USD') }
  
  FlexibleUSD = (Money | ((Integer | StringToInt) >> IntToMoney)) >> (USD | ToUSD)
end

FlexibleUSD.parse('1000') # Money(USD 10.00)
FlexibleUSD.parse(1000) # Money(USD 10.00)
FlexibleUSD.parse(Money.new(1000, 'GBP')) # Money(USD 15.00)
```



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



### Using in case statements

Plumb type definitions implement `#===(object) Boolean`, so they can be used in `case` statements.

```ruby
Adult = Types::Hash[name: String, age: Types::Integer[18..]]
Child = Types::Hash[name: String, age: Types::Integer[...18]]

def sell_alcohol?(person)
  case person
  when Adult
    :yes
  when Child
    :no
  else
    :ask_for_id
  end
end

sell_alcohol?(name: 'Joe', age: 40) # :yes
sell_alcohol?(name: 'Joan', age: 16) # :no
sell_alcohol?(name: 'Dorian Gray') # :ask_for_id
```



Because types support `#===`, they can actually be used as matchers for other types.

```ruby
MetaPerson = Types::Hash[Adult]
```

... But I'm not sure how useful that is.

### Use with pattern matching

```ruby
data = [{ name: 'Joe', age: 40 }, { name: 'Joan', age: 16 }]

case data
  in [Adult => adult, Child => child] then puts "adult: #{adult}, child: #{child}"
  in [Child => child, Adult => adult] then puts "child: #{child}, adult: #{adult}"
end
```



### Type-specific Rules

TODO

### Custom types

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

  def call(result)
    result.valid("#{gr} #{result.value}")
  end
end

MyType = Types::String >> Greeting.new('Hola')
```

You can return `result.invalid(errors: "this is invalid")` to halt processing.


### JSON Schema

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



## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ismasan/plumb.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
