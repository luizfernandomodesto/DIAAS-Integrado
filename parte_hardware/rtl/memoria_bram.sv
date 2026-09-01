`timescale 1ns / 1ps

module memoria_bram #(
    parameter int LARGURA_DADO = 32,
    parameter int PROFUNDIDADE = 1024
)(
    input  logic                            clk,
    input  logic                            habilita_escrita,
    input  logic [$clog2(PROFUNDIDADE)-1:0] endereco,
    input  logic [LARGURA_DADO-1:0]         dado_entrada,
    output logic [LARGURA_DADO-1:0]         dado_saida
);

    logic [LARGURA_DADO-1:0] ram [0:PROFUNDIDADE-1];

    always_ff @(posedge clk) begin

        if (habilita_escrita) begin
            ram[endereco] <= dado_entrada;
        end
        
        dado_saida <= ram[endereco];
    end

endmodule