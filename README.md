# Plumb

Composable data validation and coercion in Ruby. WiP.

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
  Email = String[/&/]
end

# Use them
result = Types::String.resolve("hello")
result.success? # true
result.errors # nil

result = Types::Email.resolve("foo")
result.success? # false
result.errors # ""
```



### `#resolve(value) => Result`

`#resolve` takes an input value and returns a `Result::Success` or `Result::Halt`

```ruby
result = Types::Integer.resolve(10)
result.success? # true
result.value # 10

result = Types::Integer.resolve('10')
result.success? # false
result.value # '10'
result.errors # 'must be an Integer'
```



## #parse(value) => value

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
type.resolve('a') # Success
type.resolve('x') # Failure
```

For arrays, it checks that all elements in array are included in options.

```ruby
type = Types::Array.options(['a', 'b'])
type.resolve(['a', 'a', 'b']) # Success
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
class User
  def self.create(attrs)
    new(attrs)
  end
end

UserType = Types::String.build(User, :create)
```

You can also pass a block

```ruby
UserType = Types::String.build(User) { |name| User.new(name) }
```

Note that this case is identical to `#transform` with a block.

```ruby
UserType = Types::String.transform(User) { |name| User.new(name) }
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

result.success? # true

result = Company.resolve(
  name: 'ACME',
  employees: [{ name: 'Joe' }]
)

result.success? # false
result.errors[:employees][0][:age] # ["must be a Numeric"]
```



### Hash maps

You can also use Hash syntax to define a hash map with specific types for all keys and values:

```ruby
currencies = Types::Hash[Types::Symbol, Types::String]

currencies.parse(usd: 'USD', gbp: 'GBP') # Ok
currencies.parse('usd' => 'USD') # Error. Keys must be Symbols
```



### `Types::Array`

```ruby
names = Types::Array[Types::String.present]
names_or_ages = Types::Array[Types::String.present | Types::Integer[21..]]
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



### Plumb::Schema

TODO

### Plumb::Pipeline

TODO

### Plumb::Struct

TODO

## Composing types with `#>>` ("And")

```ruby
Email = Types::String.match(/@/)
Greeting = Email >> ->(result) { result.success("Your email is #{result.value}") }

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



### Type-specific Rules

TODO

### Custom types

Compose procs or lambdas directly

```ruby
Greeting = Types::String >> ->(result) { result.success("Hello #{result.value}") }
```

or a custom class that responds to `#call(Result::Success) => Result::Success | Result::Halt`

```ruby
class Greeting
  def initialize(gr = 'Hello')
    @gr = gr
  end

  def call(result)
    result.success("#{gr} #{result.value}")
  end
end

MyType = Types::String >> Greeting.new('Hola')
```



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
