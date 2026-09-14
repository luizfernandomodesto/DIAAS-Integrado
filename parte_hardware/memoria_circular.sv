`timescale 1ns / 1ps

// Guarda as ultimas PROFUNDIDADE amostras recebidas. Quem decide ONDE
// escrever (o endereco circular) e o controlador_fsm_streaming.sv, nao
// este modulo - aqui e so o armazenamento em si.
module memoria_circular #(
    parameter int LARGURA_DADO = 32,
    parameter int PROFUNDIDADE = 127
)(
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             habilita_escrita,
    input  logic [$clog2(PROFUNDIDADE)-1:0]  endereco_escrita,
    input  logic signed [LARGURA_DADO-1:0]   dado_entrada,
    input  logic [$clog2(PROFUNDIDADE)-1:0]  endereco_leitura,
    output logic signed [LARGURA_DADO-1:0]   dado_saida
);

    logic signed [LARGURA_DADO-1:0] buffer [0:PROFUNDIDADE-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PROFUNDIDADE; i++) begin
                buffer[i] <= '0;
            end
        end else begin
            dado_saida <= buffer[endereco_leitura]; // leitura com 1 ciclo de atraso
            if (habilita_escrita) begin
                buffer[endereco_escrita] <= dado_entrada;
            end
        end
    end

endmodule
