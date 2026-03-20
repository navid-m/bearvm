local function main()
    local sum = 0

    for i = 0, 100000000 - 1 do
        sum = sum + i
    end

    print(sum)
    io.flush()
    return 0
end

return main()
