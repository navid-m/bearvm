local function fib(n)
    if n < 2 then
        return n
    else
        local n1 = n - 1
        local n2 = n - 2
        local r1 = fib(n1)
        local r2 = fib(n2)
        return r1 + r2
    end
end

local function main()
    local n = 28
    local result = fib(n)
    print(result)
    io.flush()
    return 0
end

return main()