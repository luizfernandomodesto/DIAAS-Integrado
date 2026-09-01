`timescale 1ns / 1ps

module memoria_pesos #(
    parameter int LARGURA_DADO = 32,
    parameter int PROFUNDIDADE = 1024
)(
    input  logic                            clk,
    input  logic [$clog2(PROFUNDIDADE)-1:0] endereco,
    output logic [LARGURA_DADO-1:0]         dado_saida
);

    logic [LARGURA_DADO-1:0] rom [0:PROFUNDIDADE-1];

    initial begin

        $readmemh("pesos_modelo.hex", rom);
    end

    always_ff @(posedge clk) begin
        dado_saida <= rom[endereco];
    end

endmodule