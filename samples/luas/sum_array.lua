local function fill_array(arr, n)
    for i = 0, n - 1 do
        arr[i] = i * 2
    end
end

local function sum_array(arr, n)
    local sum = 0
    for i = 0, n - 1 do
        sum = sum + arr[i]
    end
    return sum
end

local function main()
    local n = 1000000
    local arr = {}

    for i = 0, n - 1 do
        arr[i] = 0
    end

    fill_array(arr, n)
    local result = sum_array(arr, n)

    print(result)
    io.flush()
    return 0
end

return main()
