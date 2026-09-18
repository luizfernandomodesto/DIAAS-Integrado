`timescale 1ns / 1ps

// Multiplica e acumula: acumulador += peso * dado_in, a cada ciclo habilitado.
// "limpa" zera o acumulador, que e como cada nova conta comeca do zero.
module mac_dsp_streaming (
    input  logic               clk,
    input  logic               rst_n,
    input  logic                habilita,
    input  logic                limpa,
    input  logic signed [31:0] peso,
    input  logic signed [31:0] dado_in,
    output logic signed [63:0] acumulador
);

    logic signed [63:0] mult_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_reg   <= 64'd0;
            acumulador <= 64'd0;
        end else begin
            if (habilita) begin
                mult_reg <= peso * dado_in;
            end

            if (limpa) begin
                acumulador <= 64'd0;
            end else if (habilita) begin
                acumulador <= acumulador + mult_reg;
            end
        end
    end

endmodule
