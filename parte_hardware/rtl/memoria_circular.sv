`timescale 1ns / 1ps

// Guarda as ultimas PROFUNDIDADE amostras. Quem escolhe o endereco e a FSM.
module memoria_circular #(
    parameter int LARGURA_DADO = 32,
    parameter int PROFUNDIDADE = 127
)(
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             limpa,
    input  logic                             habilita_escrita,
    input  logic [$clog2(PROFUNDIDADE)-1:0]  endereco_escrita,
    input  logic signed [LARGURA_DADO-1:0]   dado_entrada,
    input  logic [$clog2(PROFUNDIDADE)-1:0]  endereco_leitura,
    output logic signed [LARGURA_DADO-1:0]   dado_saida
);

    // O `=` nos lacos e de proposito: o Verilator nao aceita `<=` a array em for
    logic signed [LARGURA_DADO-1:0] buffer [0:PROFUNDIDADE-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < PROFUNDIDADE; i++) begin
                buffer[i] = '0;
            end
        end else if (limpa) begin
            // Zera o historico sem reset geral, pra trocar de ROI
            for (int i = 0; i < PROFUNDIDADE; i++) begin
                buffer[i] = '0;
            end
            dado_saida <= '0;
        end else begin
            dado_saida <= buffer[endereco_leitura]; // leitura com 1 ciclo de atraso
            if (habilita_escrita) begin
                buffer[endereco_escrita] <= dado_entrada;
            end
        end
    end

endmodule
