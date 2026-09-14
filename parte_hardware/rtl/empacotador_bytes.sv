`timescale 1ns / 1ps

module empacotador_bytes (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        dado_valido_8b,
    input  logic [7:0]  dado_8b,
    output logic        dado_valido_32b,
    output logic [31:0] dado_32b
);

    logic [1:0] contador_bytes;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            contador_bytes  <= 2'd0;
            dado_32b        <= 32'd0;
            dado_valido_32b <= 1'b0;
        end else begin
            dado_valido_32b <= 1'b0;

            if (dado_valido_8b) begin

                dado_32b <= {dado_32b[23:0], dado_8b};
                contador_bytes <= contador_bytes + 2'd1;

                if (contador_bytes == 2'd3) begin
                    dado_valido_32b <= 1'b1;
                end
            end
        end
    end

endmodule