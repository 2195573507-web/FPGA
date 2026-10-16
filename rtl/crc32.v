// ===========================================================================
// crc32.v --- zlib / 以太网 CRC-32 (反射实现, poly 0xEDB88320)
//
// 与 Python zlib.crc32() 完全一致: init=0xFFFFFFFF, 反射, 末取反。
// 字节串行接口: init 拉高一拍复位, 之后每 en 一拍吃一个字节 (MSB 先入的字节序
// 与包内字节顺序一致)。
// ===========================================================================
module crc32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,
    input  wire        en,
    input  wire [7:0]  data,
    output wire [31:0] crc_raw,
    output wire [31:0] crc
);
    reg [31:0] r;

    function [31:0] step;
        input [31:0] c;
        input [7:0]  d;
        integer    i;
        reg [31:0] x;
        begin
            x = c ^ {24'd0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            step = x;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    r <= 32'hFFFFFFFF;
        else if (init) r <= 32'hFFFFFFFF;
        else if (en)   r <= step(r, data);
    end

    assign crc_raw = r;
    assign crc     = ~r;
endmodule
