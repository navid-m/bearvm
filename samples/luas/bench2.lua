local function main()
    local n = 1000000
    local arr = {}

    for i = 0, n - 1 do
        arr[i] = { x = i, y = i * 2 }
    end

    local sum = 0
    for i = 0, n - 1 do
        local p = arr[i]
        sum = sum + p.x + p.y
    end

    print(sum)
    io.flush()
    return 0
end

return main()
